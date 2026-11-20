# A hot code purge can leave held tool closures that fail until restart

Status: needs-triage
Category: bug

## Parent

ADR 0017 (hold server descriptions once in shared storage).

## Problem

An HTTP endpoint and every connection runtime now keep their server
description, including tool handlers and context builders, in
`persistent_term` for their lifetime. When a closure lives on a process heap
and its module's old code is purged during a hot upgrade, the purge kills
that process, or waits for it to release the code. A closure held in
`persistent_term` does neither. The holder keeps running, and a call that
reaches a purged closure can fail with `badfun` until the endpoint or runtime
restarts.

Services deployed by restarting the release are unaffected. Whether Relay
supports hot code upgrade at all is undecided.

## Behavior to decide

Decide whether hot upgrade is in scope. If it is, a purge of a module whose
closures a holder keeps must either restart that holder or fail its calls
with a defined, observable error. If it is not, the README and the ADR say
so.

## Acceptance criteria

- The design states whether Relay supports hot code upgrade of tool and
  context modules.
- If supported, a test purges a tool module under a running endpoint and
  observes the defined outcome.

## Out of scope

Release handling, appups and relups.

## Gate

`nix flake check`, `nix run .#design-gate-check -- docs/design .`,
`nix develop --command bash scripts/test.sh`.

## When to stop and ask

Before choosing between restarting holders and failing calls: that is a
behavior decision for the repository owner.
