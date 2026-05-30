# Security Policy

Senani handles people's email locally, so security and privacy are the product. We take reports seriously.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Instead, report privately via GitHub's [private vulnerability reporting](https://github.com/vishalquantana/senani/security/advisories/new),
or email **security@quantana.in** with:

- a description of the issue and its impact,
- steps to reproduce, and
- any suggested remediation.

We'll acknowledge within a few business days and keep you updated through to a fix and disclosure.

## Scope of special interest

Because Senani's promise is "nothing leaves your Mac," we especially want to hear about:

- any code path that sends user mail, content, or derived data to a server other than the user's own Google account,
- any unexpected outbound network connection,
- insecure storage of OAuth tokens or local data,
- anything that weakens the on-device-only guarantee.

## Our commitments

- **No telemetry or analytics**, anonymous or otherwise.
- OAuth tokens stored in the **macOS Keychain**; least-privilege scopes.
- Local data stays in a user-owned SQLite store.
