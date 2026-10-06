# Changelog

## Unreleased

- Typed MCP `2026-07-28` server and client: reusable definitions, native contextual handlers, tools, resources, prompts, completion, paged declarations and input-required continuations.
- Buffered HTTP mounting and streaming Mist serving; stdio and in-process clients; bounded transport and runtime settings, cancellation grace, live registry updates and subscriptions.
- Bearer admission, exact resource/scopes, RFC 6750 challenges and RFC 9728 metadata through a caller verifier. Per-call correlation, headers, deadlines, cancellation and idempotency metadata retain their distinct authority.
- Opaque client errors carry correlation, detailed reasons and submission evidence. Generic typed-output/content/metadata ports support application-owned composition; discovered replies preserve absence versus explicit null.
- Intentional listener shutdown keeps its linked caller alive while unexpected listener failure still propagates.
- Native design, vocabulary, coverage and [ADRs](docs/adr/) consolidate the unpublished construction history. Context/verifier callback time remains outside the invocation budget; [ADR-0008](docs/adr/0008-admission-budget-remains-unresolved.md) records the unresolved ownership contract.

Relay has no published release. Version `0.1.0` remains unchanged. Retained
compatibility, client OAuth, extensions and acceptance gaps are explicit in the
[native design](docs/design/design.typ#pending-updates).
