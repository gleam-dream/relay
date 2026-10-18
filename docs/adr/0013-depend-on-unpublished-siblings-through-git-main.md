# Depend on unpublished siblings through Git main and test coordinated changes by source capture

<a id="adr-0013"></a>

## Decision

- Relay's manifest depends on Sinal, HTTP Gun and JSON Blueprint through Git dependencies on their `main` branch. `manifest.toml` holds the resolved commit and is the only lock. No commit appears in `gleam.toml`, and no second file records one. A sibling moves only when a person runs `gleam update <package>`; no job or script updates siblings.
- A change that must land across Relay and a sibling before publication is verified by a local-source capture: a whole-graph copy of the current sources that a retained consumer builds and tests. The capture never edits the source manifests or the lock.
- Application manifests import Relay and Blueprint the same way, and their own manifests lock them.

## Rationale and alternatives

- A path override on Relay alone does not override its transitive Git requirements, so a consumer would silently build against the locked siblings and prove nothing about the coordinated change. A whole-graph capture is the only form that tests the change that is actually proposed.
- A commit in `gleam.toml`, in a second pin file and in the manifest is three copies of one fact. They drift, and each sibling change needs a bump commit in every dependent. The manifest alone is written by the tool and cannot disagree with itself.
- A frozen archive of a sibling is a fourth copy and adds a refresh step; Gleam fetches Git dependencies directly.
- CI needs no sibling checkout, because Gleam fetches the dependencies like any other. Sibling repositories are public, so no deploy keys or broader token permissions are required. Fork pull requests use the same jobs for the same reason.
- Publishing before a consumer exercises the coordinated change would turn the first external user into the integration test.

## Current contract

- [Validation and extension ownership](../design/design.typ#validation-and-extension-ownership) states the dependency and capture obligations. The capture procedure is in [AGENTS.md](../../AGENTS.md) and [README.md](../../README.md).
