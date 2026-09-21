# Relay Wave 2 final focused review

## Verdict

- **PASS — the final residual finding is accepted for the delivered local HTTP subset.** Handler progress is now backpressured through the runtime owner and transport writer, the runtime mailbox remains bounded under a held writer, and an SSE delivery failure closes the runtime and kills its active workers. The broker records the first failure, so a dead SSE actor cannot impose one timeout per queued progress frame.
- This is not full Wave 2 or full-package acceptance. The deferred rows in `WAVE-2-REPORT.md` remain unfinished, including subscription routing and notifications, dynamic registry changes, logging emission, full typed client and stdio client coverage, local TLS evidence, broader process-cleanup evidence, authorization, legacy compatibility, interoperability fixtures, and the public test kit.
- The target is the dirty Relay working tree against checkpoint `ce718db`. This review is intentionally limited to the single HIGH finding retained by `relay-wave2-rereview.md` and direct cancellation/timeout regressions from its repair.

## Residual finding verification

No blocking finding remains in the reviewed path.

The handler's progress callback now uses a synchronous call to the runtime owner. The owner does not acknowledge the callback until it has reduced the progress event and completed the status writer. A producer therefore cannot enqueue its full burst independently of the socket. The regression holds the writer during a 128-value burst, measures the runtime owner's actual mailbox, and requires at most one queued message before releasing the writer.

The live HTTP runtime now uses a status-returning writer. A rejected or timed-out broker delivery returns `Error`, and the runtime immediately closes its state and kills every active worker. The broker marks itself failed on an absent actor, response-limit failure, actor write failure, or actor acknowledgement timeout; later deliveries reject without another actor wait. The loopback regression resets the real TCP peer after receiving the first SSE data event during a 100,000-value producer burst, observes the worker PID terminate within one second, and proves the producer never finishes the burst.

One in-flight writer call may still occupy the configured request timeout. That is the deliberate delivery bound, not an unbounded progress backlog: only one producer call is admitted through that boundary, the outer runtime delivery returns failure at the same bound, and close/stop or invocation-timeout messages then run without a queue of progress frames ahead of them. The source contains no cyclic wait among the worker, runtime, broker, and SSE actor. The worker waits only for the runtime; the runtime and broker each use bounded transport receives; the actor returns the write result; and any failure closes the runtime. I found no cancellation/timeout deadlock introduced by the synchronous progress repair within the claimed local HTTP subset.

## Regression quality

- `runtime_progress_backpressure_bounds_mailbox_test` directly measures the runtime owner rather than inferring backpressure from successful writes. Its held writer makes the producer attempt the remaining burst while only one progress call can be outstanding.
- `live_sse_progress_burst_disconnect_cancels_worker_test` uses a real loopback socket and reset, captures the real worker PID, and checks both prompt exit and incomplete production. It exercises live SSE delivery failure during sustained producer pressure.
- The full test suite passed twice independently, so both timing-sensitive regressions held on repeated runs.

## Independent evidence

- `nix develop --command gleam test --target erlang` passed twice: **88 passed, 0 failed** on each run.
- `scripts/conformance/run-server-suite.sh` passed: **40 scenarios, 106 checks passed, 0 failed**. `input-required-result-missing-input-response` emitted **0 checks**, so this is 106 emitted checks rather than 40 independently asserted scenario passes.
- `nix develop --command gleam format --check src test` passed.
- `nix develop --command gleam check --target erlang` passed with the already-recorded unused-constructor and deferred authorization/test-kit TODO warnings.
- `git diff --check ce718db` passed.

## Acceptance boundary

Accepted: the previously rejected claim for worker-driven progress, response backpressure, live SSE delivery failure, and disconnect cancellation in the delivered local HTTP subset. The producer boundary is synchronous, the observed owner mailbox is bounded, transport failure reaches the runtime, active workers are killed, and the failed broker does not repeat dead-actor waits.

Not accepted: complete Wave 2, complete MCP coverage, or release readiness. The partial status and deferred ownership recorded in `WAVE-2-REPORT.md` remain authoritative. The passing conformance result covers every emitted check in the pinned server HTTP suite; it does not fill the zero-check scenario or establish the deferred client, stdio, TLS, authorization, compatibility, interoperability, soak, fuzz, matrix, or test-kit scope.
