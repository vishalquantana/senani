# Contributing to Senani

Thanks for your interest in Senani — a completely offline, agentic AI email client and CRM for macOS.
We're building in the open and contributions are very welcome.

> **Status: pre-alpha.** The codebase is just getting started. Right now the most valuable contributions
> are **design feedback, architecture review, and ideas** via [Issues](https://github.com/vishalquantana/senani/issues)
> and [Discussions](https://github.com/vishalquantana/senani/discussions). Code-level `good first issue`s
> will appear as the first Swift lands.

## Principles (please read before proposing features)

Senani has a few non-negotiables. PRs that violate them won't be merged:

1. **Nothing leaves the Mac.** No cloud AI, no third-party servers, **no telemetry or analytics** — not even
   anonymous. The only permitted network calls are to the user's own Gmail/Google account.
2. **Agents propose, the human approves.** Anything outbound (replies, sends, bookings) is a draft/proposal
   by default. No silent auto-sending.
3. **On-device first.** Inference runs locally via MLX. No "fallback to a cloud model."
4. **Auditable.** Keep the code clear and the data-flow honest. The privacy claim is the whole brand.

## How to contribute

1. **Open an issue first** for anything non-trivial, so we can agree on the approach before you build.
2. Fork, branch (`feat/...` or `fix/...`), and keep changes focused.
3. Match the surrounding code style; write tests where it makes sense.
4. Open a PR describing **what** and **why**, and link the issue.

## Tech stack

- **SwiftUI** (macOS 14+), Apple Silicon
- **`mlx-swift`** + **Gemma** for on-device inference
- **SQLite** (+ vector search) for the local store
- **Gmail** / **Google Calendar** APIs via scoped OAuth

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Code of Conduct

Be kind and constructive. We follow the spirit of the
[Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).

## License

By contributing, you agree your contributions are licensed under the project's **AGPL-3.0** license.
