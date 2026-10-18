# Gate every change through one registry of fast, ci, design and full profiles

<a id="adr-0012"></a>

## Decision

- One registry in `scripts/check.py` defines every verification obligation. Four profiles select from it: `fast`, `ci`, `design` and `full`, where `full` is the union of `ci` and `design`.
- CI runs the `ci` and `design` profiles as separate required jobs. Local work runs the same commands, so a local pass and a CI pass mean the same thing.
- Each profile retains per-check logs, results, dependency revisions and environment and lock metadata under `.artifacts/PROFILE`. Gates check the tree and never repair it.

## Rationale and alternatives

- Separate scripts per concern drifted: a check added to CI was easy to omit locally, and a local shortcut could pass while CI failed. A single registry makes the obligation list one reviewable artifact.
- Splitting `fast` from `ci` keeps the inner loop short. Compiler controls, the frozen schema corpus and the conformance suite are slow and need the pnpm toolchain, so they belong to the wider profile.
- Keeping `design` separate lets a documentation-only change run its own gate without the protocol suite, while `full` still requires both.
- Authored Erlang under `src`, `test` and `dev` is compiled independently with `erlc -Werror`, because Gleam's own warnings-as-errors build does not see hand-written Erlang.
- Frozen MCP and TLS fixtures, the pnpm lockfile and deliberate negative compiler fixtures are excluded from authored formatting and lint, because their bytes are evidence. Ruff checks syntax, imports and undefined names; it is not a type checker.
- The compiled usage examples in `examples/relay_usage` belong to `fast`: they are one more package with a format, a strict build and a test run, registered in the same registry, so a package without a gate owner fails preflight. [ADR 0014](0014-keep-usage-as-compiled-examples-and-oracle-evidence-as-a-document.md) records why.
- No benchmark harness or latency claim belongs to this gate.

## Current contract

- [Validation and extension ownership](../design/design.typ#validation-and-extension-ownership) states the profiles and what each evidence layer can and cannot prove. [AGENTS.md](../../AGENTS.md) lists the commands.
