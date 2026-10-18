# Agent Instructions

`relay` implements frozen MCP `2026-07-28` server and client behavior for Gleam over stdio and Streamable HTTP. The design layer under `docs/` owns contracts, vocabulary and rationale; read it and the relevant ADR before changing behavior.

Before changing a public facade, read the public API guidelines in the [Oversight repository](https://github.com/gleam-dream/oversight). Check common use, advanced configuration, caller-owned types and failure handling through a separate consumer. Preserve the full intended capability scope.

## Tooling

- `nix develop` (or direnv): pinned Gleam, Erlang/OTP 29, rebar3, Node/pnpm, Python/jsonschema 4.26.0 and authored-tooling checks.
- `nix fmt -- PATH...`: formats named authored files via treefmt. Keep formatting scoped; frozen protocol/TLS and negative compiler fixtures are excluded.
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted.
- `gleam test`: runs the test suite.

## Verification

Run the shared registry from this checkout:

```sh
nix develop --command python3 -B scripts/check.py fast
nix develop --command python3 -B scripts/check.py full
```

- `fast`: tree formatting, Ruff correctness lint, ShellCheck, actionlint, gate regressions, strict native/Gleam build, all root tests, and the format, build and tests of the compiled usage examples in `examples/relay_usage`.
- `ci`: all `fast` checks plus paired compiler controls, the jsonschema 4.26.0 frozen corpus and mutations, checksums and pins, and the complete pinned server conformance suite.
- `design`: render freshness, vocabulary, links and layer integrity.
- `full`: all `ci` and `design` obligations. CI requires the `ci` and `design` jobs.

Focused commands: `cd examples/relay_usage && gleam test` (usage examples; `gleam run -m relay_usage/<module>` runs one), `sh scripts/conformance/run-server-suite.sh` (server suite), `python3 -B scripts/check_negative_fixtures.py` (compiler controls), `sh scripts/verify_checksums.sh` (frozen fixtures), and the design-gate commands in the fence below.

Local-source experiments run from the [Oversight](https://github.com/gleam-dream/oversight) checkout, which captures the whole sibling source graph into a new output directory per run.

## References

- [docs/ORACLE.md](docs/ORACLE.md): the frozen MCP `2026-07-28` schema, the pinned `@modelcontextprotocol/conformance` server suite, the jsonschema validator and the scoped peers Relay is compared with, with their pins, classification rules and limits. Update it with any change to a pin, the corpus or the suite.
- [examples/relay_usage](examples/relay_usage/README.md): compiled and run usage recipes. Change them with any public API change, because the fast gate builds and runs them.
- Relay has no benchmark harness and makes no latency claim, so there is no `docs/BENCHMARKS.md`. Add one, linked from here and from `docs/ORACLE.md`, if a benchmark is introduced.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — GitHub issues in `gleam-dream/relay`, accessed with
`gh issue list --repo gleam-dream/relay` and `gh issue view NUMBER --repo gleam-dream/relay`.
Labels bind roles as follows: `needs-triage` → `needs-triage`,
`needs-info` → `question`, `ready-for-agent` → `ready-for-agent`,
`ready-for-human` → `ready-for-human`, `in-progress` → `in-progress`,
`done` → `done`, `wontfix` → `wontfix`, `bug` → `bug`,
and `enhancement` → `enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design gate** — `nix run .#design-gate-check -- docs/design .` checks render freshness,
vocabulary references and layer integrity (exit 0 clean, 1 violation, 2 error).
The gate is supplied by the pinned `design-layer` flake input.
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
rebuilds the rendered document. `nix run .#design-gate-context -- docs/design --estimate`
estimates agent context; the same command without `--estimate` emits ephemeral
Markdown. `--manifest`, `--preview`, and `--section PATH --expect-digest DIGEST`
support loading selected sections. A bare Typst compilation does not run the gate.

**Context verification** — use native semantic blocks for lists, tables,
models and behavior. After authoring, verify context estimation and a selected
section export as well as rendering and the design gate.
Run these commands sequentially for each layer; they share its generated
`.render` workspace.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->
