# Senani — Rules Engine & Conversational Assistant (Design Spec)

**Date:** 2026-05-31
**Status:** Approved design — ready for implementation planning
**Scope:** A unified, on-device **rules engine** and **conversational assistant** for Senani, plus four
adjacent capabilities (rule simulation, Reply Zero, attachment parse→insights, analytics) and a
**voice/style learning** profile for drafting. Inspired by Inbox Zero's plain-English rules and the
Hermes-style "chat with your inbox" pattern, re-architected for Senani's hard constraints: **on-device
only, approval-first, nothing leaves the Mac.**

---

## 1. Goals & non-goals

### Goals
- Let users author **plain-English automations** ("rules") that orchestrate Senani's existing agents
  and built-in actions — the thing Inbox Zero does well — but running on the local model.
- Provide a **conversational assistant** (in-app chat) as the primary control surface: ask about the
  inbox, issue commands, and **create/edit rules by chatting** (the "Hermes" experience).
- Keep everything **on-device** and **approval-first**: reversible actions may auto-run; outbound/
  irreversible actions always route to the Approval queue.
- Make automations **trustworthy on a small local model** via deterministic filters, grammar-constrained
  decoding, and faithful dry-run simulation.

### Non-goals (deferred to future specs)
- Remote chat bridges (Slack / Telegram / email-the-agent). These route mail through third parties and
  break the offline guarantee. May return later as an explicit, clearly-labelled opt-in.
- Office-document parsing (.docx/.pptx/.xlsx) — requires LibreOffice; PDFs + images are the core path.
- Multi-account support.
- Cloud-model fallback of any kind (violates project principle #3).

---

## 2. Constraints (project principles this design must honor)
1. **Nothing leaves the Mac** — no cloud AI, no third-party servers, no telemetry. Only network hop is
   the user's own Gmail/Google account.
2. **Agents propose, the human approves** — anything outbound is a draft/proposal by default.
3. **On-device first** — inference via MLX/Gemma; no Python, no server, no cloud fallback.
4. **Auditable** — clear data flow; every automated action is logged with its trigger.

---

## 3. Architecture overview

This design adds **one new layer** (the Rule Engine, built on a shared Action Kernel) and **one new
surface** (the Assistant panel) to Senani's existing stack.

```
SwiftUI app (macOS 14+, gold-glass)
  ├─ Inbox cockpit / Approval queue / Activity log     (exists)
  └─ Assistant panel            ◀── NEW  (right-side, ⌘K-invokable conversational chat)
        │
  Rule Engine                   ◀── NEW  routing layer; also the executor for chat
        ├─ Filter pass     (instant, structured conditions — pure Swift, every mail)
        ├─ AI predicate pass (one batched grammar-constrained Gemma call, only when needed)
        └─ Action Kernel   ◀── NEW  shared action vocabulary  ─────────┐
              │                                                        │
  Agent Engine (Triage · Reply Drafter · Booking · …)  ◀── runAgent() action
  Local LLM (MLX/Gemma)         Local store (SQLite + vectors)
```

### 3.1 The Action Kernel (heart of the design)
One enum of side-effecting operations that **both** the Rule Engine and the Assistant speak. Two
triggers, one execution path → identical behavior, audit, and undo whether a rule or a chat turn caused
the action.

Actions:

| Action | Class | Notes |
|---|---|---|
| `label(name)` | reversible | apply/remove Gmail label |
| `archive` | reversible | |
| `markRead` / `markUnread` | reversible | |
| `star` / `unstar` | reversible | |
| `move(label)` | reversible | |
| `flagNeedsReply` | reversible | powers Reply Zero |
| `fileAttachment(folder)` | reversible | saves attachment to a local folder |
| `parseDoc` | reversible | runs the parse→extract→index pipeline (§7) |
| `runAgent(id)` | depends on agent output | e.g. Lead Qualifier; its *outbound* sub-actions still queue |
| `draft(...)` | reversible | prepares a Gmail draft (no send) |
| `reply(...)` | **outbound** | always → Approval queue |
| `forward(...)` | **outbound** | always → Approval queue |
| `send(...)` | **outbound** | always → Approval queue |
| `markSpam` | **outbound/irreversible** | always → Approval queue |
| `localWebhook(name)` | reversible | local-only HTTP to a user-registered localhost endpoint; **no external hosts** |

**Safety classification is a property of the kernel, not of each feature.** Reversible actions may
auto-execute (subject to rule autonomy). Outbound/irreversible actions **always** route to the Approval
queue regardless of a rule's autonomy setting — the kernel tag overrides an over-eager `auto`.

### 3.2 Data flow for an incoming mail
1. Sync pulls new mail into the local store.
2. Rule Engine runs the **filter pass** for all enabled rules — pure-Swift structured matching, every mail.
3. For rules whose structured filters matched **and** that carry an `aiPredicate`, the engine makes **one
   batched, grammar-constrained Gemma call** per mail returning a yes/no per predicate.
4. Matched rules' actions execute via the Action Kernel: reversible actions run now (per autonomy);
   outbound actions are enqueued in the Approval queue.
5. Every kernel action is written to `actions_log` with its trigger (rule id or chat turn id).

---

## 4. The Rule model

Stored in SQLite, editable in the UI **or** by chat.

```
Rule {
  id, name, enabled: bool
  conditions {
    match: all | any | none
    structured: [               // evaluated instantly in Swift
      from(addr) | to(addr) | domain(d) | subjectContains(s) | bodyContains(s)
      | hasAttachment | listUnsubscribeHeader | isInThread | olderThan(duration) | label(name) | ...
    ]
    aiPredicate?: string         // optional plain-English judgment, e.g. "is asking about pricing"
  }
  actions: [Action]              // from the Action Kernel
  autonomy: ask | prepare | auto // per-rule graduation ladder
  runOn: incoming | existing | both
}
```

### 4.1 Hybrid matching pipeline (battery-aware)
- **Structured conditions** are evaluated instantly in Swift on every mail — no model involved.
- **AI predicate** runs **only** when a rule's structured part already matched and a predicate exists.
- All pending predicates for a single mail are **batched into one grammar-constrained Gemma call**
  returning one boolean per predicate. A 30-rule setup with 25 pure-structured rules costs **at most one
  small LLM call per mail, often zero.**

### 4.2 Autonomy ladder (per rule)
- `ask` — the whole matched action set is queued for approval.
- `prepare` — reversible preparations (e.g. the `draft(...)` action, labels) are staged for one-click
  commit rather than firing automatically. (Named `prepare`, not `draft`, to avoid colliding with the
  `draft(...)` *action*.)
- `auto` — reversible actions fire silently; **outbound actions still route to Approval** (kernel safety
  tag wins).
- **New rules default to `ask`.** Users graduate a rule to `prepare`/`auto` as trust builds, typically
  after watching it in simulation and the Approval queue.

---

## 5. The Assistant (conversational chat)

A persistent conversational panel (right-side, invokable via ⌘K). All write operations are expressed as
**tool-calls over the Action Kernel**; reads use a small set of read-only query tools. Optional UI
labeling: rules as **"Standing Orders,"** the assistant as **"Command"** (brand flavor; the spec uses
neutral terms).

### 5.1 Three job types
1. **Inbox Q&A (read-only):** "what needs me today?", "summarize the Acme thread", "who haven't I replied
   to this week?" → scoped retrieval over the local store/vectors. No approval needed.
2. **Commands:** "draft a reply to Sarah", "archive everything from Notion", "unsubscribe from these" →
   emits Actions. Reversible actions run immediately with an inline **Undo**; outbound actions land in the
   Approval queue.
3. **Rule authoring/editing:** "make a rule: label invoices and flag overdue ones" → the Assistant emits a
   **draft Rule object**, renders it human-readably, runs an **inline simulation** (§6) against recent
   mail, and the user approves before it is saved. Editing/disabling a rule by chat uses the same flow.

### 5.2 Context & memory
- The Assistant sees: the current selection/thread, the visible inbox view, the user's rules, and a
  **scoped retrieval** over the local store/vectors — never the whole mailbox blindly (keeps the prompt
  small for Gemma).
- Conversation memory persists per session (`chat_sessions`) and is summarized into the local store for
  continuity across sessions.

### 5.3 Reliability on a small model
- **All rule-emission and tool-calls use grammar-constrained JSON decoding** (MLX constrained sampling),
  so Gemma cannot emit a malformed action or rule. This is essential at this model size.

---

## 6. Rule simulation (dry-run)

Before any rule is saved/activated — and on demand from a rule's detail view — the engine runs it against
the user's **last N messages** (default 200, configurable) in read-only mode using the **same execution
code with side-effects suppressed** (faithful, not approximate).

- Produces a **diff list**: e.g. "would label 14, archive 9, draft 2 replies, flag 3 as needs-reply,"
  each expandable to the exact messages and the action that would fire.
- For rules with an `aiPredicate`, simulation shows **which** messages the model judged yes/no, so an
  over-broad predicate is caught before touching live mail.
- Simulation is the on-ramp to the autonomy ladder: **simulate → activate at `ask` → watch in Approval →
  graduate to `auto`.** Chat-authored rules show the simulation inline in the conversation.
- Simulation runs are recorded in `rule_runs`.

---

## 7. Attachment parse → extract → index → insights

`parseDoc` / `fileAttachment` actions feed a local pipeline that turns documents into searchable insight.

1. **Extract:** `liteparse` — its **Rust core linked into Swift via FFI** (or the prebuilt binary bundled
   in the app), with **Tesseract OCR bundled**. Extracts text + spatial layout from **PDFs and images**.
   Runs fully on-device — no cloud, no API keys, no Python/Node (the Python package wraps a Node CLI and
   is therefore **not** used; we integrate the Rust core directly).
2. **Field extraction:** a Gemma pass (grammar-constrained) pulls structured fields — invoice number,
   amount, due date, vendor, contract parties/dates, renewal clauses, etc.
3. **Index:** results are stored as structured rows (`documents`, `document_fields`) **and** chunked into
   the vector index.
4. **Insights:** documents become chat-queryable ("what invoices are due this month?", "find the contract
   with the auto-renewal clause") and feed the **Invoice/Finance** agent.

Office formats (.docx/.pptx/.xlsx) require LibreOffice and are **deferred**. PDFs + images are the core path.

---

## 8. Reply Zero — "needs *your* reply"

Distinct from the existing **Follow-up** agent (which watches threads awaiting *their* reply). Reply Zero
tracks threads where the ball is in **the user's** court.

- A lightweight classifier uses structured signals (user is a recipient, last message is not from the
  user, message contains a question/ask) plus an **optional Gemma confirm**, then sets `needsReply` via the
  `flagNeedsReply` action.
- Surfaces as: a dedicated **"Needs you" view** in the cockpit, a count in the **Daily Digest**, and a
  first-class chat query ("what am I behind on?").
- Optionally pre-drafts replies via the existing **Reply Drafter** agent so the queue is one-tap.
  Pre-drafting is a reversible `draft`; **sending always routes through Approval.**
- Implemented as a **built-in Rule**, so it is consistent with the kernel and its sensitivity is editable
  in plain English.

---

## 9. Voice / Style learning (drafting in the user's voice)

So drafts sound like the user from day one, a background pass learns the user's writing style from their
**Sent** history when mail loads/syncs.

- **Extract style signals** from sent mail: typical greeting/sign-off, formality, sentence length, warmth,
  emoji/punctuation habits, common phrases, and **per-recipient/per-domain variation** (clients vs.
  teammates).
- **Store** a compact **Voice Profile** + exemplar snippets in the local store (`voice_profile`; exemplars
  in the vector index).
- **Use at draft time (RAG, no fine-tuning):** the Reply Drafter retrieves the closest-matching past sent
  messages (same person/topic) and conditions Gemma on them + the profile — so even a small model mimics
  the user's voice.
- **Incremental refresh** as new sent mail arrives.
- **Chat-adjustable:** "be more concise with clients", "drop the 'Best,' sign-off" → stored as profile
  overrides.
- Powers both the Reply Drafter agent and chat-authored drafts. Fully on-device; the profile lives in the
  user's SQLite file.

---

## 10. Analytics

A read-only dashboard over the local store (no new action types; independent of the engine):
- Who emails you most; top senders/domains clogging the inbox; volume over time; reply-latency.
- **Rule/agent activity** — what your automations did this week (sourced from `actions_log` / `rule_runs`).
- The same data is chat-queryable.

---

## 11. Data model (new SQLite tables)

| Table | Purpose |
|---|---|
| `rules` | rule definitions (conditions, actions, autonomy, runOn) |
| `rule_runs` | simulation + live evaluation records per rule |
| `actions_log` | every Action Kernel execution, with trigger (rule id / chat turn id), reversibility, undo state |
| `voice_profile` | learned style profile + chat overrides; exemplars indexed in vectors |
| `needs_reply` | Reply Zero state per thread |
| `documents` / `document_fields` | parsed attachments + extracted structured fields |
| `chat_sessions` | assistant conversation history + summaries |

All tables are local to the user's SQLite file.

---

## 12. Privacy & local-model guardrails
- Everything on-device; the **only** webhook action is `localWebhook` (localhost only — no external hosts).
- **Grammar-constrained JSON decoding** for all action/rule emission (no malformed side effects).
- **Outbound actions always route to Approval** regardless of autonomy — enforced at the kernel.
- The **audit log** (`actions_log`) records every kernel action with its trigger, supporting the
  "auditable" principle and undo.

---

## 13. Component boundaries (for implementation)
- **Action Kernel** — pure action definitions + executor + safety classification + audit logging. Knows
  nothing about rules or chat.
- **Rule Engine** — owns the Rule model, the hybrid matching pipeline, autonomy enforcement, and
  simulation. Depends on the Action Kernel and the local LLM (for predicates).
- **Assistant** — conversational front-end; translates NL into read-tool calls and Action Kernel calls /
  Rule drafts. Depends on the Action Kernel, Rule Engine (to author/simulate rules), and the store.
- **Voice Profile service** — builds/refreshes the profile from Sent mail; consumed by Reply Drafter.
- **Document pipeline** — liteparse FFI + field extraction + indexing; exposed via `parseDoc`.
- **Analytics** — read-only queries/views over the store; no write path.

Each unit communicates through a well-defined interface and can be understood and tested independently.

---

## 14. Open questions for the implementation plan
- Exact Gemma prompt + grammar schema for (a) batched predicate evaluation and (b) rule emission.
- liteparse integration mechanism: Rust-staticlib-via-FFI vs. bundled prebuilt binary — pick during
  planning based on build ergonomics.
- Vector index choice for the local store (existing Senani decision) and how exemplars/doc-chunks share it.
- Minimum N and performance budget for simulation on large mailboxes.
