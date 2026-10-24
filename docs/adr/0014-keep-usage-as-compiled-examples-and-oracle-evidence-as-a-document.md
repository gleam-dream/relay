# Keep usage as compiled examples and oracle evidence as a retained document

<a id="adr-0014"></a>

## Decision

- Usage lives as runnable code in `examples/relay_usage`, one module per recipe, plus a short README usage section that mirrors it. There is no standalone prose usage guide.
- The examples are a separate package that depends on Relay by path. The `fast` profile formats, builds with warnings as errors and tests it, and the registry refuses a package that has no gate owner.
- The oracle references, their pins, the comparison classification and the limits of each claim live in [docs/ORACLE.md](../ORACLE.md), which [AGENTS.md](../../AGENTS.md) and the [README](../../README.md) link. The design states what each evidence layer proves and links that document instead of repeating its tables.
- Relay has no benchmark harness, so it has no `docs/BENCHMARKS.md`. A benchmark would add that document, cross-linked with the oracle document.
- No changelog is kept before the first release.

## Rationale and alternatives

- A prose guide with code blocks drifts silently when the API changes. Code that the gate compiles and runs fails the build instead, so the documented recipes stay true.
- Compiled README snippets inside the root test suite compiled the code but left the recipes as test helpers, not programs a reader can run. A separate example package also proves the public API is usable from outside the package.
- Folding the oracle pins into ADR 0007 and the design buried facts a reader needs when changing a pin. A single reference document keeps the pins findable and the ADR to the decision.
- A separate package costs a second dependency resolution in the gate. That is accepted because it is the same graph a consumer resolves.

## Current contract

- [Validation and extension ownership](../design/design.typ#validation-and-extension-ownership) states the evidence layers and the profile that builds the examples. [ADR 0007](0007-freeze-independent-evidence-and-retain-provenance.md) records the frozen evidence and [ADR 0012](0012-gate-with-one-registry-of-fast-ci-and-design-profiles.md) the registry.
