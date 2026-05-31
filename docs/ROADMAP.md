# Senani — Roadmap

> A single master vision, delivered in phases. Status: pre-alpha.

## Phase 0 — Foundation
- [ ] SwiftUI app skeleton (macOS 14+, gold-glass shell)
- [ ] Gmail OAuth + sync into local SQLite store
- [ ] `mlx-swift` + Gemma loading, in-app model picker (by hardware)
- [ ] Local store schema (mail, threads, contacts) + vector search
- _Outcome: your mail, local, with a model running — no agents yet._

## Phase 1 — Agent Engine + first slice  ← the demoable MVP
- [ ] Agent Engine: orchestrator, approval queue, activity log, autonomy dials
- [ ] **Triage** agent (classify + prioritize + label)
- [ ] **Reply Drafter** agent (drafts in your voice → Gmail draft)
- _Outcome: mail comes in → triaged → reply drafted → you approve → draft in Gmail._

## Phase 2 — Complete Core  → ships the $99 build
- [ ] **Booking** agent (calendar-aware scheduling)
- [ ] **Daily Digest** agent
- [ ] **Inbox Hygiene** agent (unsubscribe / declutter)

## Phase 3 — Pro sales suite  → ships the $199 tier
- [ ] **Lead Qualifier**
- [ ] **Proposal Tracker**
- [ ] **Follow-up**
- [ ] **Outreach**
- [ ] **Invoice / Finance**
- [ ] Lightweight pipeline / CRM view

## Phase 4 — Go to market
- [ ] Landing + pricing page (gold-glass)
- [ ] Public launch (Show HN, r/LocalLLaMA, r/selfhosted, r/macapps, Product Hunt)

## Deferred — Packaging & licensing
- [x] Code signing + notarization (see Scripts/package_and_sign.sh + docs/SIGNING.md)
- [ ] One-time license keys (offline verification)
- [ ] Auto-update

---

Ideas and feedback: please open a [Discussion](https://github.com/vishalquantana/senani/discussions)
or [Issue](https://github.com/vishalquantana/senani/issues).
