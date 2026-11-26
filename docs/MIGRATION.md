# Migrating from Relay 0.2 to 0.3

Relay 0.3.0 is a breaking release. Change the dependencies in `gleam.toml` first:

```toml
relay = ">= 0.3.0 and < 0.4.0"
json_blueprint = ">= 3.0.0 and < 4.0.0"
```

If your application imports Sinal or HTTP Gun itself, move those to `sinal >= 0.2.0 and < 0.3.0` and `http_gun >= 0.4.0 and < 0.5.0`, and read their own migration guides ([JSON Blueprint](https://github.com/gleam-dream/json_blueprint/blob/main/docs/MIGRATION.md), [Sinal](https://github.com/gleam-dream/sinal/blob/main/docs/MIGRATION.md), [HTTP Gun](https://github.com/gleam-dream/http_gun/blob/main/docs/MIGRATION.md)). Then work through the sections below. They are ordered by how many applications they affect.

| Change                                                                                            | Who must act                                                          |
| ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| [Stdio servers need `-noinput`](#stdio-servers-need--noinput)                                     | Every stdio server                                                    |
| [`stdio.Config` is a record](#stdioconfig-is-a-record)                                            | Stdio servers that configure `serve_with`                             |
| [Stdio children get an allow-listed environment](#stdio-children-get-an-allow-listed-environment) | Clients that launch a stdio server needing environment variables      |
| [Invalid tool arguments are a tool error](#invalid-tool-arguments-are-a-tool-error)               | Clients that match `-32602` for argument errors; telemetry consumers  |
| [`next_notification` waits the whole wait](#next_notification-waits-the-whole-wait)               | HTTP subscribers that relied on an early `Ok(None)`                   |
| [HTTP listen streams have a lifetime](#http-listen-streams-have-a-lifetime)                       | HTTP subscribers that keep one stream open for more than an hour      |
| [`http.stop` waits for the listener to close](#httpstop-waits-for-the-listener-to-close)          | Code that polls the port after `http.stop`, or relies on a 5 s cutoff |
| [`reducer.Received` takes a decoded frame](#reducerreceived-takes-a-decoded-frame)                | Custom transports that drive `relay/reducer` directly                 |
| [New `ConfigField` and `StdioError` variants](#new-configfield-and-stdioerror-variants)           | Code with an exhaustive `case` over these types                       |
| [Wire changes](#wire-changes)                                                                     | Peers that depended on the old header encoding or on dropped requests |

New in 0.3.0 and not breaking: `telemetry.arguments_rejected_event`, `reducer.outcome_rejected_arguments`, `client.with_environment`, `client.with_listen_timeout`, `reducer.decode`, `reducer.frame_correlation`, `runtime.send_decoded`, and HTTP client support for event-stream responses to ordinary requests.

## Stdio servers need `-noinput`

**What changed.** `stdio.serve` and `stdio.serve_with` read standard input through one port of their own. A VM started without `-noinput` runs its own terminal reader on standard input, and `serve` now returns `Error(StdinOwnedByVm)` before reading anything. After `serve` starts, every logger handler that wrote to standard output writes to standard error for the rest of the VM's life, and the runtime's `io` output goes to standard error.

**Why.** With two readers on standard input, the VM's reader could take bytes of a request, so a short request went unanswered while standard input stayed open. Log lines on standard output corrupted the protocol stream.

**What to do.** Start the server's VM with `-noinput`, for example in the command the host launches:

```sh
ERL_FLAGS=-noinput gleam run -m my_server
```

Do not print to standard output from processes started before `serve`, and do not use `erlang:display`, which writes to the descriptor directly.

## `stdio.Config` is a record

**What changed.** `stdio.Config` is a public record with two fields, `runtime` and `write_timeout`. `stdio.with_runtime` and `stdio.with_chunk_size` are removed, and so is `StdioError.InvalidChunkSize`. A write to standard output that takes longer than `write_timeout` (default 5 s) ends `serve` with `StdoutBroken`. A request that arrives while the runtime's exchange limit is reached now gets JSON-RPC error `-32000` instead of no answer.

**Why.** A parent that stopped reading held the server forever. The chunk size no longer bounded anything, because the port delivers what each read returns.

**What to do.**

```gleam
// 0.2
stdio.serve_with(service, context, stdio.config() |> stdio.with_runtime(limits))

// 0.3
stdio.serve_with(service, context, stdio.Config(..stdio.config(), runtime: limits))
```

Delete every `with_chunk_size` call. Set `write_timeout` when your parent may read more slowly than 5 s per reply:

```gleam
stdio.Config(..stdio.config(), write_timeout: duration.seconds(30))
```

## Stdio children get an allow-listed environment

**What changed.** A child launched with `client.stdio` no longer inherits the application's environment. It receives `HOME`, `LOGNAME`, `PATH`, `SHELL`, `TERM` and `USER` (on Windows `APPDATA`, `HOMEDRIVE`, `HOMEPATH`, `LOCALAPPDATA`, `PATH`, `PROCESSOR_ARCHITECTURE`, `SYSTEMDRIVE`, `SYSTEMROOT`, `TEMP`, `USERNAME`, `USERPROFILE` and `PROGRAMFILES`; Windows names match without regard to case, so `Path` is kept), plus the variables you pass with the new `client.with_environment`.

**Why.** Every secret in the application's environment reached every tool process it launched.

**What to do.** Pass each variable the server needs:

```gleam
client.stdio("my-server", [])
|> client.with_environment([#("API_KEY", key)])
```

A name must be non-empty and contain no `=`, and no name or value may contain a NUL byte; `connect` refuses the configuration otherwise with `InvalidConfig(Environment)`. Setting an environment on an HTTP or in-process target is refused the same way.

## Invalid tool arguments are a tool error

**What changed.** A `tools/call` whose arguments do not decode is answered with a successful JSON-RPC response carrying an `isError` result. Its text starts with `Invalid arguments:` and names the path and JSON Blueprint's own description of the failure, such as `$["text"]: expected a string`, never the value that was sent. A message your input codec wrote (with `codec.try_map` or `codec.decode_failure`) never reaches the caller: the text says `custom validation failed` at that path instead. The server's observers receive the codec's message in the new `[relay, invocation, arguments_rejected]` telemetry event (`telemetry.arguments_rejected_event()`, fields `tool`, `path` and `detail`), and a transport that drives the reducer reads it with `reducer.outcome_rejected_arguments`. A Relay client sees `Ok(client.ToolFailed(blocks, None))` where 0.2 returned `Error` with `RpcError(-32602, ..)`. The invocation telemetry reports status `ToolFailed` instead of `Failed`.

**Why.** MCP `2026-07-28` reports input validation as a tool execution error, so the model can correct its call.

**What to do.** Handle `ToolFailed` (already required for handler failures). Replace any match on `-32602` for argument errors with a match on `ToolFailed`. Requests with a malformed envelope, such as a missing tool name, still get `-32602`. To log why your own codec refused arguments, observe `telemetry.arguments_rejected_event()`; its `detail` can contain the value your message names, so treat it as you treat the arguments.

## `next_notification` waits the whole wait

**What changed.** Over HTTP, `client.next_notification(subscription, wait)` returns `Ok(None)` only when the whole `wait` passed without a notification. In 0.2 a keepalive or another event without a notification ended the wait early with `Ok(None)`. Stdio and in-process subscriptions already behaved this way.

**What to do.** Treat `Ok(None)` as "the wait ended", never as "the stream is idle" or "the stream ended" (a closed stream is an `Error`). Pass a shorter `wait` if you need to return sooner.

## HTTP listen streams have a lifetime

**What changed.** Every HTTP request now runs under a finite deadline. Ordinary calls (everything except `listen`) keep the request timeout, 30 s by default, set with `client.with_timeout`; the listen timeout applies only to `listen`. An established `subscriptions/listen` stream over HTTP stays open for the client's listen timeout, 1 hour by default, or until an earlier `with_deadline` on the view. Then `next_notification` returns an error with `TimedOut`.

**What to do.** Reopen the subscription with `client.listen` when it ends with `TimedOut`. Change the lifetime with `client.with_listen_timeout(config, duration.hours(4))`; a zero or negative timeout is refused with `InvalidConfig(ListenTimeout)`. Stdio and in-process subscriptions have no such bound.

## `http.stop` waits for the listener to close

**What changed.** `http.stop` returns once the endpoint has exited. For a listener started with `http.start` or `http.supervised`, its listening socket is closed by then, so a new connection is refused, and a request in flight has been cut off. In 0.2 `stop` returned after at most 5 s, possibly while the socket still accepted connections.

**What to do.** Remove any loop that waits for the port to refuse connections after `stop`. If your shutdown path relied on `stop` returning within 5 s, put your own bound around it.

## `reducer.Received` takes a decoded frame

**What changed.** `reducer.Received(exchange, context, bytes, correlation)` is now `reducer.Received(exchange, context, frame, correlation)` with `frame: reducer.Frame`. `runtime.send_frame` keeps its signature but no longer gives up after 5 s: it waits while the runtime is busy and returns `RuntimeStopped` if the runtime exits.

**Why.** Each inbound frame is parsed once. The waiting `send_frame` is the back-pressure that holds a transport's reader while the runtime writes to a slow peer.

**What to do.**

```gleam
// 0.2
reducer.step(state, reducer.Received(exchange, context, bytes, None))

// 0.3
reducer.step(state, reducer.Received(exchange, context, reducer.decode(bytes), None))
```

A transport that needs the decoded request before submitting it can call `reducer.decode` itself and submit the result with `runtime.send_decoded`.

## New `ConfigField` and `StdioError` variants

An exhaustive `case` needs a branch for each:

- `client.ConfigField`: `ListenTimeout` and `Environment`.
- `stdio.StdioError`: `InvalidWriteTimeout(timeout)` and `StdinOwnedByVm`. `InvalidChunkSize` is removed.

## Wire changes

These need no code change in a Relay application, but a peer may notice them:

- `Mcp-Name` is sent plain, or in the `=?base64?...?=` form for values that are not plain ASCII, as MCP `2026-07-28` requires. It is never percent-encoded. A Relay endpoint compares the header with the body literally, after decoding the Base64 form only. `relay/testing.request` builds the header the same way.
- Over HTTP, a body deeper than the depth limit is refused with the depth error even when it is not valid JSON. Both answers are HTTP 400.
- Every event stream from a Relay endpoint carries `connection: close` and ends with its final chunk. A subscription the endpoint ends reports `ConnectionClosed(Completed)` to a Relay client.
- The stdio client never writes a queued request whose caller already gave up, and answers it with not-sent evidence. It ignores a response that arrives after its request was cancelled, for the last 256 requests given up in flight; any other unrelated response still fails the call.
