<div align="center">

<!-- TODO: replace with the gold-on-obsidian logo once the visual identity is rendered -->
<h1>⟢ Senani</h1>

### A private army of AI agents that works while you sleep — completely offline.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-D4AF37.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B-1c1c1e)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1%2B-1c1c1e)](#requirements)
[![Status](https://img.shields.io/badge/status-pre--alpha-orange)](#status)
[![Stars](https://img.shields.io/github/stars/vishalquantana/senani?style=social)](https://github.com/vishalquantana/senani/stargazers)

**Your inbox, run by a private team of AI agents — on your Mac, and nowhere else.**
No cloud AI. No subscriptions. No telemetry. Nothing ever leaves your machine.

</div>

---

> ### 🚧 Status: pre-alpha
> Senani is in active design and early development. This repository is the home of the project, its
> architecture, and its roadmap. ⭐ **Star it to follow along** — the first builds land soon.
> See the [**Roadmap**](docs/ROADMAP.md) and [**Architecture**](docs/ARCHITECTURE.md).

<div align="center">

🎬 _Demo coming soon — agents triaging the inbox and drafting replies, live and on-device._

</div>

## What is Senani?

**Senani** _(सेनानी / సేనాని — "the general who leads the army")_ is an open-source, **completely offline**
AI email client and CRM for macOS. It connects to your Gmail, syncs your mail into a local store, and
runs a **local large language model** (Google's **Gemma**, via Apple's **MLX**) **entirely on your Mac**.

Every bit of AI — reading, classifying, drafting, reasoning — happens on-device. A team of focused agents
triages your mail, drafts replies in your voice, books meetings, qualifies leads, tracks proposals, and
chases follow-ups — **while you sleep**. You wake up to a handled inbox and a queue of one-tap approvals.

It's built for **solopreneurs, consultants, agencies, and small B2B sales teams** who live in Gmail and
refuse to send their client correspondence to someone else's servers.

## Why Senani?

Every commercial "AI email" tool — Superhuman, Shortwave, Fyxer, Cora — sends your mail to **cloud LLMs**
(OpenAI, Anthropic, Google). Senani doesn't. The only thing your Mac ever talks to is **your own Gmail account.**

```
            YOUR MAC  —  everything below runs on-device
┌──────────────────────────────────────────────────────────────────┐
│  Senani (native SwiftUI app · gold-glass UI)                       │
│     Inbox cockpit · Approval queue · Activity log                  │
│        │                                                           │
│     Agent Engine  →  routes each mail to the right agent(s)        │
│        │                          │                                │
│     Local LLM (MLX + Gemma)   Local store (SQLite + vectors)       │
│     draft · triage · extract  mail · contacts · pipeline           │
└────────────────────────┬───────────────────────────────────────────┘
                         │   ← the ONLY network hop (your own account)
                         ▼
              Gmail  (fetch mail · save drafts · send)
```

- 🔒 **100% local AI** — zero cloud inference, zero AI API costs, zero data brokering.
- 🕵️ **No telemetry, no accounts** — auditable, open source, mail stored in a local SQLite file you own.
- 💸 **Pay once** — a one-time license for the official build. No subscription, ever.
- ✋ **Agents propose, you approve** — nothing outbound sends without you. Per-agent autonomy dial + full audit log.

## The agents

Senani isn't one assistant — it's a **formation** of focused agents, each doing one job well.

| Tier | Agent | What it does |
|------|-------|--------------|
| **Core** | 🗂️ **Triage** | Classifies + prioritizes every mail; applies Gmail labels |
| **Core** | ✍️ **Reply Drafter** | Drafts replies in *your* voice → saved as a Gmail draft |
| **Core** | 📅 **Booking** | Detects scheduling asks, reads your calendar, proposes/confirms times |
| **Core** | ☀️ **Daily Digest** | Your morning cockpit: what came in, what needs you, what's drafted |
| **Core** | 🧹 **Inbox Hygiene** | Spots newsletters/cold spam, suggests bulk unsubscribes |
| **Pro** | 🎯 **Lead Qualifier** | Scores inbound leads, extracts company/intent/budget, drafts a first reply |
| **Pro** | 📑 **Proposal Tracker** | Tracks quotes & proposals + their status; nudges the stale ones |
| **Pro** | 🔁 **Follow-up** | Watches quiet threads awaiting *their* reply; suggests timed nudges |
| **Pro** | 📣 **Outreach** | Proactive warm-outreach drafts from your own contacts and history |
| **Pro** | 🧾 **Invoice / Finance** | Spots invoices & payment asks, extracts amounts/due dates, flags overdue |

## How it works

| Layer | Tech |
|-------|------|
| App shell | Native **SwiftUI** (macOS 14+), the "gold-glass" aesthetic |
| Local LLM | **Gemma** running in-process via **`mlx-swift`** (Apple Silicon) — no Python, no server, no extra install |
| Local store | **SQLite** (+ vector search) — mail, contacts, pipeline, agent memory |
| Connectors | **Gmail** + **Google Calendar** (OAuth, scoped); tokens in the macOS Keychain |

Full design in [**docs/ARCHITECTURE.md**](docs/ARCHITECTURE.md).

## Requirements

- **macOS 14 (Sonoma) or later**
- **Apple Silicon** (M1 or newer) — required for on-device MLX inference
- A **Gmail** account
- RAM guides the model: **8 GB** runs the default small Gemma, **16 GB+** unlocks larger models via the in-app picker.

## Install

> Builds are not yet published (pre-alpha). Two paths are planned:

**1. Build from source** _(free, always)_
```bash
git clone https://github.com/vishalquantana/senani.git
cd senani
# open in Xcode 16+ and run — full instructions land with the first alpha
```

**2. Official signed build** _(one-time license — coming soon)_
The notarized, auto-updating official build will be **$99 (Core)** / **$199 (Pro)**.
See [_Why pay if it's open source?_](#why-pay-if-its-open-source)

## Senani vs cloud AI email

| | **Senani** | Fyxer / Cora | Superhuman AI | Inbox Zero (hosted) |
|---|:--:|:--:|:--:|:--:|
| AI runs **on your device** | ✅ | ❌ | ❌ | ❌ |
| Works **fully offline** | ✅ | ❌ | ❌ | ❌ |
| **No third-party** sees your mail | ✅ | ❌ | ❌ | ❌ |
| **One-time** payment | ✅ | ❌ (sub) | ❌ (sub) | ❌ (sub) |
| **Multi-agent** sales suite | ✅ | partial | ❌ | partial |
| **Open source** | ✅ | ❌ | ❌ | ✅ |

## Roadmap

- [ ] **Phase 0** — Foundation: app shell, Gmail sync → local store, MLX + Gemma + model picker
- [ ] **Phase 1** — Agent Engine + **Triage** & **Reply Drafter** (the demoable MVP)
- [ ] **Phase 2** — Complete Core (Booking, Daily Digest, Inbox Hygiene) → **$99** build
- [ ] **Phase 3** — Pro sales suite + lightweight pipeline/CRM → **$199** tier
- [ ] **Phase 4** — Landing + pricing page
- [ ] Packaging, notarization, license keys, auto-update

Details in [**docs/ROADMAP.md**](docs/ROADMAP.md).

## Why pay if it's open source?

Senani is, and always will be, **fully open source under AGPL-3.0** — read every line, build it yourself,
modify it freely. The one-time license buys the **convenience**, not the code:

- a **signed, notarized** build that opens with a double-click (no Xcode),
- **automatic updates**,
- **support**, and
- it **funds full-time development**.

This is the same model behind SQLite, Plausible, and Immich: give away the source, charge for the official
build. "Senani" the name and logo are trademarks — forks must rebrand, the project stays free.

## Contributing

Contributions are very welcome — see [**CONTRIBUTING.md**](CONTRIBUTING.md). Look for
[`good first issue`](https://github.com/vishalquantana/senani/labels/good%20first%20issue) once the first
code lands. Security disclosures: [**SECURITY.md**](SECURITY.md).

## License

[**AGPL-3.0**](LICENSE) © Quantana. The "Senani" name and logo are trademarks of the project owner.

## FAQ

**Is my email really private?** Yes. Mail syncs from Gmail to a local store on your Mac; all AI runs
on-device. No email content or AI inference ever touches a third-party server.

**Does it work fully offline?** All AI does. Fetching and sending mail naturally needs to reach Gmail
(that's where your mail lives) — but that's the only network call, to your own account.

**Why Apple Silicon only?** On-device inference via MLX needs Apple Silicon. It's what makes Senani fast
and private at the same time.

**Gmail only?** At launch, yes. Other providers are on the radar.

---

<div align="center">
<sub>Built for people who want their inbox handled — without handing it over.</sub>
</div>
