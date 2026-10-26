# Consume published siblings from Hex

<a id="adr-0016"></a>

## Decision

Use Hex version requirements for published Sinal, HTTP Gun and JSON Blueprint.
Each package's `manifest.toml` locks the resolved versions and checksums. Reconcile
the root and usage consumer through Gleam, then run the full repository gate.

This supersedes the Git dependency decision in [ADR 0013](0013-depend-on-unpublished-siblings-through-git-main.md).
Its whole-graph source capture remains the way to qualify coordinated changes to
unpublished siblings. Historical oracle and compatibility pins remain frozen.

## Rationale

Hex dependencies let an ordinary consumer resolve one released version of each
library. Retaining Git requirements for published siblings would give consumers
different package sources for the same library and prevent Hex publication.
