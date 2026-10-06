# Keep whole-request admission budgeting unresolved until ownership is defined

<a id="adr-0008"></a>

## Observed gap

- At Relay `d448fe2e1dd7898d699fa2f13bf5cc5d86beaff5`, the request process synchronously constructs native context before dispatch starts the invocation and response wait budgets. `new_protected` runs bearer verification inside that callback.
- A prior disposable public consumer used a 20 ms endpoint timeout and a barrier-held context builder, then separately a barrier-held verifier. Neither answered during a 100 ms hold; releasing the barrier allowed HTTP 200. The 23 retained consumer tests and two observation probes passed; the probes themselves were disposable and are not installed as runtime tests here.
- A callback can therefore occupy an admitted request slot and delay disconnect observation outside the advertised request budget. This is a deadline/ownership gap, not an authentication bypass.

## Documentation ruling

- State the implemented timing honestly: the endpoint setting bounds invocation and response waits after context construction, while callback time remains caller-owned and separately bounded. This correction removes a false documentation guarantee without accepting the runtime as the final intended model.
- Keep a native ruling for an end-to-end budget. No callback signature, spawned-worker wrapper, response classification or runtime fix is approved by this documentation migration.

## Alternatives that require a decision

- Carry a shared remaining deadline through admission and dispatch, with explicit callback cancellation/cleanup ownership. Late verifier success must never start tool work after expiry, and capacity must be released independently of late callback return.
- Preserve current callback process affinity and require explicit bounded callback ports. This retains links, Subjects and handle ownership but leaves application policy responsible for whole-request admission and requires a clearly narrower endpoint promise.
- Isolating arbitrary callbacks in a worker could permit forced cancellation, but changes the owner of Subjects, links, newly started handles and cleanup. It must not be introduced as an equivalent invisible wrapper.

## Required proof for any later correction

- Gate context/verifier after entry under capacity one, assert expiry responds and releases admission capacity before barrier release, and prove late success never dispatches. Monitor callback children and retain an accepted verification+handler control within one remaining budget.
- Repeat through buffered mount and real listener paths. Include a public caller creating a Subject or linked handle inside admission so deliberate process-affinity changes are observable.

## Evidence and limits

- Current ordering is in [HTTP serve/admission/dispatch](../../src/relay/http.gleam), [verifier admission](../../src/relay/authorization.gleam), [runtime cancellation ownership](../../src/relay/runtime.gleam) and [Mist body read](../../src/relay/internal/http_mist.gleam). The public lifecycle suite remains [HTTP lifecycle tests](../../test/relay/http_lifecycle_test.gleam).
- The disposable observation did not measure incomplete body readers, slowloris capacity, peak allocation or production load. Mist pre-read slot exclusion is direct source evidence; broader claims require their own experiment.
- [HTTP endpoint and limits](../design/design.typ#http-endpoint-and-limits) captures the current behavior. The ruling ledger in the [native design](../design/design.typ) exposes the unresolved intended bound.
