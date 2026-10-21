# Agent Instructions

`relay` implements frozen MCP `2026-07-28` server and client behavior for Gleam over stdio and Streamable HTTP. The design layer under `docs/` owns contracts, vocabulary and rationale; read it and the relevant ADR before changing behavior.

Before changing a public facade, read the public API guidelines in the [Oversight repository](https://github.com/gleam-dream/oversight). Check common use, advanced configuration, caller-owned types and failure handling through a separate consumer. Preserve the full intended capability scope.

## Tooling

- When updating dependency pins, reconcile affected `manifest.toml` files in examples, consumers and nested packages through Gleam, then run the full repository gate; updating the root lock alone is insufficient.

- `nix develop` (or direnv): pinned Gleam, Erlang/OTP 29, rebar3, Node/pnpm, Python/jsonschema 4.26.0.
- `nix fmt -- PATH...`: formats named authored files via treefmt. Keep formatting scoped; frozen protocol/TLS and negative compiler fixtures are excluded.
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted.
- `gleam test`: runs the test suite.

## Validation

Use the shared tools directly, then run application tests:

```sh
nix flake check
nix run .#design-gate-check -- docs/design .
nix develop --command bash scripts/test.sh
```

For the core edit loop, run `nix develop --command gleam test`.
`scripts/test.sh` compiles and tests the retained packages and service fixtures;
it does not wrap formatting or design validation.

Focused commands: `cd examples/relay_usage && gleam test` (usage examples),
`bash scripts/conformance/run-server-suite.sh` (server suite), and
`python3 -B scripts/check_negative_fixtures.py` (compiler controls).

Dependencies: Sinal, HTTP Gun and JSON Blueprint are unpublished Git dependencies
on `main`, locked by `manifest.toml`; update one by hand with `gleam update <package>`.
Oracle comparisons fetch hash-pinned inputs lazily into the Nix store, never on shell entry.
Local-source experiments run from the Oversight checkout, which captures the whole
sibling source graph into a new output directory per run.

## References

- [docs/ORACLE.md](docs/ORACLE.md): the frozen MCP `2026-07-28` schema, the pinned `@modelcontextprotocol/conformance` server suite, the jsonschema validator and the scoped peers Relay is compared with, with their pins, classification rules and limits. Update it with any change to a pin, the corpus or the suite.
- [examples/relay_usage](examples/relay_usage/README.md): compiled and run usage recipes. Change them with any public API change, because the application test script builds and runs them.
- Relay has no benchmark harness and makes no latency claim, so there is no `docs/BENCHMARKS.md`. Add one, linked from here and from `docs/ORACLE.md`, if a benchmark is introduced.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(Updated for the repository validation policy.)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Shared design validation** — `nix run .#design-gate-check -- docs/design .`
uses the pinned design-layer implementation for render freshness, vocabulary and
layer integrity. `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
updates the rendered document; `nix run .#design-gate-context -- docs/design` exports
context. Run these tools sequentially because they share `.render`.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example or consumer source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md` using the shared pinned
package. Snips checks synchronization; existing example tests check behavior.
