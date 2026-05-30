# Senani — Architecture

> Status: design / pre-alpha. This document captures the locked architectural decisions.
> It will evolve as the first code lands.

## Product in one line

A completely offline, agentic AI email client + CRM for macOS: a private team of agents that runs your
inbox and pipeline, with **all AI on-device**.

## The trust model (the spine)

- **Agents propose; you approve.** Anything *outbound or external* — replies, booking confirmations,
  outreach — is created as a **draft/proposal**, never auto-sent by default.
- **Reversible, internal actions** (applying a label, categorizing, surfacing) *can* auto-run, governed by a
  **per-agent autonomy dial**: `Suggest → Draft → Auto-with-guardrails`.
- **Everything is logged** in an activity/audit trail.
- **No telemetry, no accounts.** OAuth tokens live in the macOS Keychain; mail lives in a local SQLite file.

## System diagram

```
                  YOUR MAC  —  everything below runs on-device
┌──────────────────────────────────────────────────────────────────┐
│  SwiftUI app  (gold-glass UI)                                      │
│   Inbox cockpit · Approval queue · Activity log · Settings         │
│        │                                                           │
│  ┌─────┴───────────────  Agent Engine  ───────────────────────┐   │
│  │  Orchestrator: routes each mail → the right agent(s)        │   │
│  │  Autonomy dials · Approval queue · Activity/audit log       │   │
│  │  Scheduler: runs on new mail + on a timer while Mac is awake │  │
│  └─────┬───────────────────────────────┬──────────────────────┘   │
│        │                               │                          │
│  LLM service (mlx-swift)         Local store (SQLite + vectors)    │
│   Gemma, 4-bit                    mail · threads · contacts        │
│   draft · triage · extract        pipeline/CRM · agent state       │
│   model picker + downloader       embeddings (semantic search/RAG) │
└────────────────────────┬───────────────────────────────────────────┘
                         │   ← the ONLY network hop (your own account)
                         ▼
          Gmail API  (read mail + labels, save drafts, send)
          Google Calendar API  (Booking agent)
```

## Components (each with one job)

| Component | Responsibility |
|-----------|----------------|
| **App shell** | UI only; renders state, captures approvals. |
| **Agent Engine** | Orchestration, scheduling, autonomy, approval queue, audit log. The brain. |
| **LLM service** | `mlx-swift` + Gemma; model download/switching; all inference. |
| **Local store** | SQLite (+ vector search) for mail, contacts, pipeline, embeddings, agent memory. |
| **Connectors** | Gmail + Calendar, OAuth-scoped; tokens in the Keychain. |

## How an agent is defined

```
Agent = {
  trigger:   which mail/events it wakes for (e.g. category = "Lead", or a daily timer)
  tools:     capabilities it may call (read thread, search store, draft reply,
             propose label, read calendar, propose hold …)
  policy:    its LLM instructions + a strict extraction schema for its task
  autonomy:  Suggest → Draft → Auto-with-guardrails  (per-agent dial)
  output:    proposals → approval queue   (or auto-apply, if reversible + allowed)
}
```

Agents **never touch Gmail directly.** They call Engine-provided tools and emit *proposals*; only the
Engine's connector executes an approved action. This isolation makes agents safe and unit-testable —
essentially pure functions from *state → proposals*.

## The pipeline

```
Gmail sync → Triage (classify + prioritize) → Orchestrator routes by category
   → subscribed agent(s) do their work → proposals land in the Approval Queue
   → you approve → Engine executes via connector → Activity Log records it
                                                  ↘ Daily Digest aggregates it all
```

**Triggers:** on new mail (poll while the Mac is awake, interval configurable), a manual "Process inbox"
button, and a daily digest at a set time. Respects Low Power / battery.

## Local model strategy

- Runtime: **`mlx-swift`**, in-process (no Python, no server, no extra install).
- Model: **Gemma** family, 4-bit quantized (e.g. `mlx-community/gemma-4-e2b-it-4bit` as the default small model).
- A **model picker** reads the live `mlx-community` catalog and offers larger variants by RAM tier (8 / 16 / 32 GB+).
- Weights download from Hugging Face on first launch and are cached locally.

## Tech stack

| Layer | Choice |
|-------|--------|
| App | Native SwiftUI, macOS 14+, Apple Silicon |
| Inference | `mlx-swift` + Gemma |
| Storage | SQLite + vector search |
| Connectors | Gmail API + Google Calendar API (scoped OAuth) |
| Secrets | macOS Keychain |

## Open questions (to resolve during implementation)

- Gmail access via Gmail API vs IMAP, and the OAuth **verification** path for a distributed app using
  restricted Gmail scopes (this affects onboarding and is a real launch consideration).
- Voice-learning approach for the Reply Drafter (few-shot RAG over Sent mail vs light fine-tune).
- Exact local schema + embedding model for semantic search.
