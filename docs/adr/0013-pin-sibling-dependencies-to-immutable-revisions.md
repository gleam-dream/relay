# Pin sibling dependencies to immutable revisions and test coordinated changes by source capture

<a id="adr-0013"></a>

## Decision

- Relay's manifest depends on Sinal, HTTP Gun and JSON Blueprint through immutable Git revisions. `sibling-revisions.txt` records the same revisions for CI, which checks out each sibling at its recorded ref with the ordinary read-only checkout token and persists no credentials.
- A change that must land across Relay and a sibling before publication is verified by a local-source capture: a whole-graph copy of the current sources that a retained consumer builds and tests. The capture never edits the source manifests or the recorded revisions.
- Application manifests use a reviewed immutable Relay revision and the same Blueprint revision when importing Relay's codecs.

## Rationale and alternatives

- A path override on Relay alone does not override its transitive Git requirements, so a consumer would silently build against the pinned siblings and prove nothing about the coordinated change. A whole-graph capture is the only form that tests the change that is actually proposed.
- Branch or tag dependencies would let a sibling change break Relay without a Relay commit. Immutable revisions keep every Relay revision reproducible.
- Sibling repositories are public, so no deploy keys or broader token permissions are required. Fork pull requests use the same jobs for the same reason.
- Publishing before a consumer exercises the coordinated change would turn the first external user into the integration test.

## Current contract

- [Validation and extension ownership](../design/design.typ#validation-and-extension-ownership) states the pin and capture obligations. The capture procedure is in [AGENTS.md](../../AGENTS.md) and [README.md](../../README.md).
