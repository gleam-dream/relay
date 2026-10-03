import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec.{type Codec}
import json/blueprint/value
import relay/reducer.{type ExchangeId}
import relay/runtime
import relay/server
import relay/subscriptions
import relay/telemetry
import relay/tool
import sinal
import sinal/correlation

type ProgressBurstNotice {
  ProgressBurstFinished
}

type SinkGateMessage {
  DecideToHold(Subject(Bool))
  StopSinkGate(Subject(Nil))
}

/// What a probe handler reports to the test that called it.
type Probe {
  HandlerStarted(pid: Pid)
  HandlerSawCancel
  HandlerCleanedUp
}

@external(erlang, "erlang", "self")
fn ffi_self() -> dynamic.Dynamic

@external(erlang, "relay_ffi", "mailbox_size")
fn ffi_mailbox_size(pid: dynamic.Dynamic) -> Int

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

// --- servers -----------------------------------------------------------------

fn property(name: String, inner: Codec(a)) -> Codec(a) {
  use value <- codec.field(name, inner, get: fn(value) { value })
  codec.success(value)
}

fn greeting() -> Codec(String) {
  property("greeting", codec.string())
}

fn greet_tool() -> tool.Tool(String) {
  tool.define("greet", property("name", codec.string()), greeting())
  |> tool.with_description("Greets a user")
  |> tool.handle_call(fn(call, user) {
    Ok(tool.complete(tool.context(call) <> ": hello " <> user))
  })
}

fn crash_tool() -> tool.Tool(String) {
  tool.define("crash", property("name", codec.string()), greeting())
  |> tool.with_description("Always crashes")
  |> tool.handle(fn(_user: String) -> Result(String, Nil) {
    panic as "Deliberate handler crash: secret-token-7B3F"
  })
}

fn slow_tool() -> tool.Tool(String) {
  tool.define("slow", property("ms", codec.int()), greeting())
  |> tool.with_description("Slow handler")
  |> tool.handle(fn(ms: Int) -> Result(String, Nil) {
    process.sleep(ms)
    Ok("finished slow")
  })
}

fn fail_tool() -> tool.Tool(String) {
  tool.define("fail", property("name", codec.string()), greeting())
  |> tool.handle(fn(_user: String) -> Result(String, String) {
    Error("private failure")
  })
}

fn ask_tool() -> tool.Tool(String) {
  tool.define("ask", property("name", codec.string()), greeting())
  |> tool.handle_call(fn(_call, _user) {
    Ok(
      tool.request_input(
        dict.from_list([
          #("confirm", tool.InputRequest(tool.Elicitation, value.Object([]))),
        ]),
      ),
    )
  })
}

fn extra_tool() -> tool.Tool(String) {
  tool.define("extra", codec.success(Nil), greeting())
  |> tool.handle(fn(_input: Nil) -> Result(String, Nil) { Ok("extra ran") })
}

fn sample_server() -> server.Server(String) {
  server.new([greet_tool(), crash_tool(), slow_tool(), fail_tool(), ask_tool()])
}

/// A handler that reports its pid, waits for its cancellation selector,
/// reports that it saw it, and then keeps running regardless.
fn stubborn_tool() -> tool.Tool(Subject(Probe)) {
  tool.define("stubborn", codec.success(Nil), codec.success(Nil))
  |> tool.handle_call(fn(call, _input) {
    let probe = tool.context(call)
    process.send(probe, HandlerStarted(process.self()))
    case process.selector_receive(tool.cancelled(call), 10_000) {
      Ok(Nil) -> process.send(probe, HandlerSawCancel)
      Error(Nil) -> Nil
    }
    process.sleep(10_000)
    Ok(tool.complete(Nil))
  })
}

/// A handler that, once cancelled, spends 100 ms stopping work it started
/// elsewhere, reports it, and returns.
fn cooperative_tool() -> tool.Tool(Subject(Probe)) {
  tool.define("cooperative", codec.success(Nil), codec.success(Nil))
  |> tool.handle_call(fn(call, _input) {
    let probe = tool.context(call)
    process.send(probe, HandlerStarted(process.self()))
    case process.selector_receive(tool.cancelled(call), 10_000) {
      Ok(Nil) -> {
        process.send(probe, HandlerSawCancel)
        process.sleep(100)
        process.send(probe, HandlerCleanedUp)
      }
      Error(Nil) -> Nil
    }
    Ok(tool.complete(Nil))
  })
}

fn probe_server() -> server.Server(Subject(Probe)) {
  server.new([stubborn_tool(), cooperative_tool()])
}

// --- frames ------------------------------------------------------------------

fn request_meta(extra: List(#(String, json.Json))) -> #(String, json.Json) {
  #(
    "_meta",
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
      ..extra
    ]),
  )
}

fn request_frame(
  id: String,
  method: String,
  params: List(#(String, json.Json)),
  extra_meta: List(#(String, json.Json)),
) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string(method)),
    #("params", json.object([request_meta(extra_meta), ..params])),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

fn discover_frame(id: String) -> BitArray {
  request_frame(id, "server/discover", [], [])
}

fn call_frame(id: String, tool_name: String, args: json.Json) -> BitArray {
  request_frame(
    id,
    "tools/call",
    [#("name", json.string(tool_name)), #("arguments", args)],
    [],
  )
}

fn greet_frame(id: String, name: String) -> BitArray {
  call_frame(id, "greet", json.object([#("name", json.string(name))]))
}

fn slow_frame(id: String, ms: Int) -> BitArray {
  call_frame(id, "slow", json.object([#("ms", json.int(ms))]))
}

fn listen_frame(id: String) -> BitArray {
  request_frame(
    id,
    "subscriptions/listen",
    [#("notifications", json.object([#("toolsListChanged", json.bool(True))]))],
    [],
  )
}

fn cancel_frame(request_id: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/cancelled")),
    #("params", json.object([#("requestId", json.string(request_id))])),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

fn nested(depth: Int) -> json.Json {
  case depth {
    0 -> json.string("leaf")
    _ -> json.object([#("a", nested(depth - 1))])
  }
}

// --- helpers -----------------------------------------------------------------

fn start_collecting(
  srv: server.Server(context),
  config: runtime.Config,
) -> #(runtime.Runtime(context), Subject(runtime.Output)) {
  let outputs = process.new_subject()
  let assert Ok(rt) =
    runtime.start(srv, config, fn(output) {
      process.send(outputs, output)
      Ok(Nil)
    })
  #(rt, outputs)
}

fn expect_write(
  outputs: Subject(runtime.Output),
  exchange: ExchangeId,
) -> String {
  let assert Ok(runtime.OutputWrite(written, bytes)) =
    process.receive(outputs, 1000)
  written |> should.equal(exchange)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn expect_close(outputs: Subject(runtime.Output), exchange: ExchangeId) -> Nil {
  let assert Ok(runtime.OutputClose(closed)) = process.receive(outputs, 1000)
  closed |> should.equal(exchange)
}

fn expect_silence(outputs: Subject(runtime.Output), ms: Int) -> Nil {
  process.receive(outputs, ms) |> should.equal(Error(Nil))
}

fn error_code(text: String) -> Int {
  let assert Ok(code) =
    json.parse(text, decode.at(["error", "code"], decode.int))
  code
}

fn structured_greeting(text: String) -> String {
  let assert Ok(greeting) =
    json.parse(
      text,
      decode.at(["result", "structuredContent", "greeting"], decode.string),
    )
  greeting
}

fn has_result(text: String) -> Bool {
  case json.parse(text, decode.at(["result"], decode.dynamic)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Forwards every event whose `listener` equals `label` to the returned
/// subject, so concurrent emitters elsewhere cannot interfere.
fn capture(
  event: sinal.Event(m, d),
  label: String,
  listener: fn(d) -> Option(String),
) -> #(sinal.Attachment, Subject(#(m, d))) {
  let events = process.new_subject()
  let attachment =
    sinal.observe(event, fn(measured, meta) {
      case listener(meta) == Some(label) {
        True -> process.send(events, #(measured, meta))
        False -> Nil
      }
    })
  #(attachment, events)
}

fn expect_event(events: Subject(#(m, d))) -> d {
  let assert Ok(#(_, meta)) = process.receive(events, 1000)
  meta
}

fn wait_down(monitor: process.Monitor, within: Int) -> process.ExitReason {
  let assert Ok(process.ProcessDown(reason: reason, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(within)
  reason
}

fn ms(count: Int) -> duration.Duration {
  duration.milliseconds(count)
}

// --- configuration -----------------------------------------------------------

pub fn invalid_runtime_config_reports_field_before_start_test() {
  let config = runtime.config() |> runtime.with_max_frame_bytes(0)
  runtime.validate(config)
  |> should.equal(Error(runtime.InvalidConfig(runtime.MaxFrameBytes)))
  let assert Error(runtime.InvalidConfig(runtime.MaxFrameBytes)) =
    runtime.start(sample_server(), config, fn(_output) { Ok(Nil) })
  Nil
}

pub fn validate_rejects_each_out_of_range_setting_test() {
  let base = runtime.config()
  [
    #(runtime.with_max_live_exchanges(base, 0), runtime.MaxLiveExchanges),
    #(runtime.with_max_live_exchanges(base, -1), runtime.MaxLiveExchanges),
    #(runtime.with_max_frame_bytes(base, 0), runtime.MaxFrameBytes),
    #(runtime.with_max_json_depth(base, 0), runtime.MaxJsonDepth),
    #(runtime.with_invocation_timeout(base, ms(0)), runtime.InvocationTimeout),
    #(runtime.with_cancellation_grace(base, ms(-1)), runtime.CancellationGrace),
    #(runtime.with_tombstone_retention(base, ms(0)), runtime.TombstoneRetention),
    #(runtime.with_max_tombstones(base, 0), runtime.MaxTombstones),
  ]
  |> list.each(fn(case_) {
    let #(config, field) = case_
    runtime.validate(config)
    |> should.equal(Error(runtime.InvalidConfig(field)))
  })
  // A zero grace period is allowed: the handler is killed at once.
  let assert Ok(_) =
    runtime.validate(runtime.with_cancellation_grace(base, ms(0)))
  let assert Ok(_) = runtime.validate(base)
  runtime.describe_start_error(runtime.InvalidConfig(runtime.MaxJsonDepth))
  |> string.contains("max_json_depth")
  |> should.be_true
}

pub fn config_defaults_test() {
  runtime.max_frame_bytes(runtime.config()) |> should.equal(1_048_576)
  runtime.invocation_timeout(runtime.config())
  |> duration.to_milliseconds
  |> should.equal(30_000)
  runtime.config()
  |> runtime.with_max_frame_bytes(2048)
  |> runtime.max_frame_bytes
  |> should.equal(2048)
}

// --- exchanges ---------------------------------------------------------------

pub fn runtime_lifecycle_test() {
  let #(rt, outputs) = start_collecting(sample_server(), runtime.config())

  let ex1 = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, ex1, "test_ctx", discover_frame("disc-1"), None)
  expect_write(outputs, ex1) |> has_result |> should.be_true
  expect_close(outputs, ex1)

  let ex2 = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, ex2, "my_ctx", greet_frame("call-1", "Alice"), None)
  expect_write(outputs, ex2)
  |> structured_greeting
  |> should.equal("my_ctx: hello Alice")
  expect_close(outputs, ex2)

  runtime.stop(rt)
}

pub fn closing_one_runtime_exchange_preserves_other_exchange_test() {
  let #(rt, outputs) = start_collecting(sample_server(), runtime.config())
  let closing = reducer.new_exchange_id()
  let survivor = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, closing, "ctx", slow_frame("slow-close", 500), None)
  runtime.exchange_closed(rt, closing)
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      survivor,
      "ctx",
      greet_frame("survivor", "Other"),
      None,
    )

  expect_close(outputs, closing)
  expect_write(outputs, survivor)
  |> string.contains("Other")
  |> should.be_true
  expect_close(outputs, survivor)
  runtime.stop(rt)
}

pub fn failed_output_closes_only_its_exchange_test() {
  let failed = reducer.new_exchange_id()
  let survivor = reducer.new_exchange_id()
  let outputs = process.new_subject()
  let assert Ok(rt) =
    runtime.start(sample_server(), runtime.config(), fn(output) {
      case output {
        runtime.OutputWrite(exchange, _) if exchange == failed -> Error(Nil)
        _ -> {
          process.send(outputs, output)
          Ok(Nil)
        }
      }
    })
  let assert Ok(Nil) =
    runtime.send_frame(rt, failed, "ctx", discover_frame("failed"), None)
  let assert Ok(Nil) =
    runtime.send_frame(rt, survivor, "ctx", discover_frame("survivor"), None)
  expect_close(outputs, failed)
  let _ = expect_write(outputs, survivor)
  expect_close(outputs, survivor)
  runtime.stop(rt)
}

pub fn duplicate_exchange_does_not_consume_live_capacity_test() {
  let config = runtime.config() |> runtime.with_max_live_exchanges(1)
  let #(rt, outputs) = start_collecting(sample_server(), config)
  let duplicate = reducer.new_exchange_id()
  let request = discover_frame("duplicate")

  let assert Ok(Nil) = runtime.send_frame(rt, duplicate, "ctx", request, None)
  let _ = expect_write(outputs, duplicate)
  expect_close(outputs, duplicate)
  // A frame on an exchange the runtime already saw is dropped silently.
  let assert Ok(Nil) = runtime.send_frame(rt, duplicate, "ctx", request, None)
  let fresh = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, fresh, "ctx", discover_frame("fresh"), None)
  let _ = expect_write(outputs, fresh)
  expect_close(outputs, fresh)

  runtime.stop(rt)
}

pub fn runtime_equal_wire_ids_on_distinct_exchanges_test() {
  let #(rt, outputs) = start_collecting(sample_server(), runtime.config())
  let ex1 = reducer.new_exchange_id()
  let ex2 = reducer.new_exchange_id()

  let assert Ok(Nil) =
    runtime.send_frame(rt, ex1, "ctx1", greet_frame("same-id", "User1"), None)
  let assert Ok(Nil) =
    runtime.send_frame(rt, ex2, "ctx2", greet_frame("same-id", "User2"), None)

  let written =
    [
      process.receive(outputs, 1000),
      process.receive(outputs, 1000),
      process.receive(outputs, 1000),
      process.receive(outputs, 1000),
    ]
    |> list.filter_map(fn(output) {
      case output {
        Ok(runtime.OutputWrite(exchange, bytes)) -> {
          let assert Ok(text) = bit_array.to_string(bytes)
          Ok(#(exchange, structured_greeting(text)))
        }
        _ -> Error(Nil)
      }
    })
  list.sort(written, fn(a, b) { string.compare(a.1, b.1) })
  |> should.equal([#(ex1, "ctx1: hello User1"), #(ex2, "ctx2: hello User2")])

  runtime.stop(rt)
}

pub fn runtime_repeated_close_test() {
  let #(rt, _outputs) = start_collecting(sample_server(), runtime.config())

  runtime.close(rt)
  runtime.close(rt)
  runtime.close(rt)

  runtime.send_frame(
    rt,
    reducer.new_exchange_id(),
    "ctx",
    discover_frame("1"),
    None,
  )
  |> should.equal(Error(runtime.RuntimeStopped))

  runtime.stop(rt)
}

// --- frame admission ---------------------------------------------------------

pub fn runtime_frame_bound_test() {
  let label = "frame-bound"
  let #(attachment, rejected) =
    capture(telemetry.frame_rejected_event(), label, fn(m) { m.listener })
  let config =
    runtime.config()
    |> runtime.with_max_frame_bytes(20)
    |> runtime.with_label(label)
  let #(rt, _outputs) = start_collecting(sample_server(), config)

  let exchange = reducer.new_exchange_id()
  let frame = discover_frame("large-1")
  runtime.send_frame(rt, exchange, "ctx", frame, None)
  |> should.equal(Error(runtime.FrameTooLarge(bit_array.byte_size(frame), 20)))
  expect_event(rejected)
  |> should.equal(telemetry.FrameRejectedMeta(
    exchange_id: reducer.exchange_id_to_int(exchange),
    problem: telemetry.FrameTooLarge,
    listener: Some(label),
  ))

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn frame_deeper_than_max_json_depth_is_rejected_test() {
  let label = "frame-depth"
  let #(attachment, rejected) =
    capture(telemetry.frame_rejected_event(), label, fn(m) { m.listener })
  let config =
    runtime.config()
    |> runtime.with_max_json_depth(8)
    |> runtime.with_label(label)
  let #(rt, outputs) = start_collecting(sample_server(), config)

  let deep = reducer.new_exchange_id()
  let frame =
    call_frame(
      "deep",
      "greet",
      json.object([#("name", json.string("x")), #("deep", nested(10))]),
    )
  runtime.send_frame(rt, deep, "ctx", frame, None)
  |> should.equal(Error(runtime.FrameTooDeep(8)))
  expect_event(rejected)
  |> should.equal(telemetry.FrameRejectedMeta(
    exchange_id: reducer.exchange_id_to_int(deep),
    problem: telemetry.NestingTooDeep,
    listener: Some(label),
  ))
  // Nothing reached the sink for the refused frame.
  expect_silence(outputs, 20)

  // A frame within the limit (discover nests four levels) is admitted.
  let shallow = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, shallow, "ctx", discover_frame("shallow"), None)
  expect_write(outputs, shallow) |> has_result |> should.be_true

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn default_max_json_depth_is_64_test() {
  let #(rt, outputs) = start_collecting(sample_server(), runtime.config())
  let frame =
    call_frame(
      "deep",
      "greet",
      json.object([#("name", json.string("x")), #("deep", nested(70))]),
    )
  runtime.send_frame(rt, reducer.new_exchange_id(), "ctx", frame, None)
  |> should.equal(Error(runtime.FrameTooDeep(64)))
  expect_silence(outputs, 20)
  runtime.stop(rt)
}

pub fn too_many_live_exchanges_is_rejected_test() {
  let label = "live-exchanges"
  let #(attachment, rejected) =
    capture(telemetry.frame_rejected_event(), label, fn(m) { m.listener })
  let config =
    runtime.config()
    |> runtime.with_max_live_exchanges(1)
    |> runtime.with_label(label)
  let #(rt, outputs) = start_collecting(sample_server(), config)

  let busy = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, busy, "ctx", slow_frame("busy", 100), None)
  let refused = reducer.new_exchange_id()
  runtime.send_frame(rt, refused, "ctx", discover_frame("refused"), None)
  |> should.equal(Error(runtime.TooManyLiveExchanges(1, 1)))
  expect_event(rejected)
  |> should.equal(telemetry.FrameRejectedMeta(
    exchange_id: reducer.exchange_id_to_int(refused),
    problem: telemetry.TooManyExchanges,
    listener: Some(label),
  ))

  // Once the busy exchange closes its slot is free again.
  let _ = expect_write(outputs, busy)
  expect_close(outputs, busy)
  let next = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, next, "ctx", discover_frame("next"), None)
  let _ = expect_write(outputs, next)

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

// --- cancellation, timeouts and crashes --------------------------------------

pub fn runtime_cancellation_test() {
  let label = "client-cancel"
  let #(attachment, cancelled) =
    capture(telemetry.invocation_cancelled_event(), label, fn(m) { m.listener })
  let config = runtime.config() |> runtime.with_label(label)
  let #(rt, outputs) = start_collecting(sample_server(), config)

  let call = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, call, "ctx", slow_frame("cancel-req-1", 300), None)
  let notification = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      notification,
      "ctx",
      cancel_frame("cancel-req-1"),
      None,
    )

  expect_close(outputs, call)
  expect_close(outputs, notification)
  let meta = expect_event(cancelled)
  meta.method |> should.equal("tools/call")
  meta.tool |> should.equal(Some("slow"))

  // The handler ignores the signal and finishes within the grace period; its
  // late result is dropped, so nothing is written for the cancelled request.
  expect_silence(outputs, 400)

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn exchange_closed_fires_cancelled_selector_then_kills_after_grace_test() {
  let probe = process.new_subject()
  let config = runtime.config() |> runtime.with_cancellation_grace(ms(200))
  let #(rt, outputs) = start_collecting(probe_server(), config)

  let exchange = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      exchange,
      probe,
      call_frame("stubborn-1", "stubborn", json.object([])),
      None,
    )
  let assert Ok(HandlerStarted(pid)) = process.receive(probe, 1000)
  let monitor = process.monitor(pid)
  let closed_at = monotonic_ms()
  runtime.exchange_closed(rt, exchange)

  let assert Ok(HandlerSawCancel) = process.receive(probe, 1000)
  expect_close(outputs, exchange)
  // The handler ignored the signal; it lives until the grace period ends.
  process.is_alive(pid) |> should.be_true
  wait_down(monitor, 2000) |> should.equal(process.Killed)
  { monotonic_ms() - closed_at >= 150 } |> should.be_true
  expect_silence(outputs, 20)

  runtime.stop(rt)
}

/// `stop` cancels every handler and waits for it to return within its grace
/// before the runtime stops; it kills only a handler that outlives it.
pub fn stop_gives_cancelled_handlers_their_grace_test() {
  let probe = process.new_subject()
  let config = runtime.config() |> runtime.with_cancellation_grace(ms(2000))
  let #(rt, _outputs) = start_collecting(probe_server(), config)
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      reducer.new_exchange_id(),
      probe,
      call_frame("cooperative-1", "cooperative", json.object([])),
      None,
    )
  let assert Ok(HandlerStarted(cooperative)) = process.receive(probe, 1000)
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      reducer.new_exchange_id(),
      probe,
      call_frame("stubborn-stop", "stubborn", json.object([])),
      None,
    )
  let assert Ok(HandlerStarted(stubborn)) = process.receive(probe, 1000)
  let cooperative_down = process.monitor(cooperative)
  let stubborn_down = process.monitor(stubborn)
  let stopped_at = monotonic_ms()
  runtime.stop(rt)
  let waited = monotonic_ms() - stopped_at

  // The cooperative handler cleaned up and returned on its own; the
  // stubborn one was killed when the grace ended, and `stop` waited for it.
  wait_down(cooperative_down, 100) |> should.equal(process.Normal)
  wait_down(stubborn_down, 100) |> should.equal(process.Killed)
  { waited >= 1900 && waited < 4000 } |> should.be_true
  let reports =
    list.filter_map([1, 2, 3, 4], fn(_) { process.receive(probe, 100) })
  list.contains(reports, HandlerCleanedUp) |> should.be_true
}

/// A runtime whose owner exits abnormally closes like `stop`: its cancelled
/// handlers keep their grace.
pub fn owner_exit_gives_cancelled_handlers_their_grace_test() {
  let probe = process.new_subject()
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let #(rt, _outputs) =
        start_collecting(
          probe_server(),
          runtime.config() |> runtime.with_cancellation_grace(ms(2000)),
        )
      let assert Ok(Nil) =
        runtime.send_frame(
          rt,
          reducer.new_exchange_id(),
          probe,
          call_frame("cooperative-2", "cooperative", json.object([])),
          None,
        )
      process.send(started, Nil)
      process.sleep(10_000)
    })
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(HandlerStarted(handler)) = process.receive(probe, 1000)
  let monitor = process.monitor(handler)
  process.send_abnormal_exit(owner, "owner crashed")

  let assert Ok(HandlerSawCancel) = process.receive(probe, 1000)
  let assert Ok(HandlerCleanedUp) = process.receive(probe, 1000)
  wait_down(monitor, 1000) |> should.equal(process.Normal)
}

pub fn zero_cancellation_grace_kills_handler_at_once_test() {
  let probe = process.new_subject()
  let config = runtime.config() |> runtime.with_cancellation_grace(ms(0))
  let #(rt, outputs) = start_collecting(probe_server(), config)

  let exchange = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      exchange,
      probe,
      call_frame("stubborn-0", "stubborn", json.object([])),
      None,
    )
  let assert Ok(HandlerStarted(pid)) = process.receive(probe, 1000)
  let monitor = process.monitor(pid)
  runtime.exchange_closed(rt, exchange)

  wait_down(monitor, 100) |> should.equal(process.Killed)
  expect_close(outputs, exchange)

  runtime.stop(rt)
}

pub fn runtime_timeout_test() {
  let label = "timeout"
  let #(attachment, crashed) =
    capture(telemetry.invocation_crashed_event(), label, fn(m) { m.listener })
  let probe = process.new_subject()
  let config =
    runtime.config()
    |> runtime.with_invocation_timeout(ms(100))
    |> runtime.with_cancellation_grace(ms(50))
    |> runtime.with_label(label)
  let #(rt, outputs) = start_collecting(probe_server(), config)

  let exchange = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      exchange,
      probe,
      call_frame("slow-1", "stubborn", json.object([])),
      None,
    )
  let assert Ok(HandlerStarted(pid)) = process.receive(probe, 1000)
  let monitor = process.monitor(pid)

  expect_write(outputs, exchange) |> error_code |> should.equal(-32_603)
  expect_close(outputs, exchange)
  let assert Ok(HandlerSawCancel) = process.receive(probe, 1000)
  let meta = expect_event(crashed)
  meta.reason |> should.equal(telemetry.HandlerTimedOut)
  meta.method |> should.equal("tools/call")
  meta.tool |> should.equal(Some("stubborn"))
  wait_down(monitor, 1000) |> should.equal(process.Killed)

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn runtime_crash_isolation_test() {
  let label = "crash"
  let #(attachment, crashed) =
    capture(telemetry.invocation_crashed_event(), label, fn(m) { m.listener })
  let config = runtime.config() |> runtime.with_label(label)
  let #(rt, outputs) = start_collecting(sample_server(), config)

  // A neighbour invocation is in flight while the other handler crashes.
  let neighbour = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, neighbour, "ctx", slow_frame("neighbour", 150), None)
  let crashing = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      crashing,
      "ctx",
      call_frame("crash-1", "crash", json.object([#("name", json.string("t"))])),
      None,
    )

  let text = expect_write(outputs, crashing)
  error_code(text) |> should.equal(-32_603)
  string.contains(text, "secret-token-7B3F") |> should.be_false
  expect_close(outputs, crashing)
  let meta = expect_event(crashed)
  meta.reason |> should.equal(telemetry.HandlerCrashed)
  meta.tool |> should.equal(Some("crash"))

  expect_write(outputs, neighbour)
  |> structured_greeting
  |> should.equal("finished slow")
  expect_close(outputs, neighbour)

  // The runtime still answers.
  let alive = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, alive, "ctx", discover_frame("alive-1"), None)
  expect_write(outputs, alive) |> has_result |> should.be_true

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

// --- telemetry metadata ------------------------------------------------------

pub fn request_admitted_runtime_observation_test() {
  let label = "admitted"
  let #(attachment, admitted) =
    capture(telemetry.request_admitted_event(), label, fn(m) { m.listener })
  let config = runtime.config() |> runtime.with_label(label)
  let #(rt, _outputs) = start_collecting(sample_server(), config)
  let corr = correlation.from_key("admitted-correlation")

  let exchange = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, exchange, "ctx", discover_frame("a"), Some(corr))
  expect_event(admitted)
  |> should.equal(telemetry.RequestAdmittedMeta(
    exchange_id: reducer.exchange_id_to_int(exchange),
    method: "server/discover",
    correlation: Some(corr),
    listener: Some(label),
  ))

  let uncorrelated = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, uncorrelated, "ctx", discover_frame("b"), None)
  let meta = expect_event(admitted)
  meta.exchange_id |> should.equal(reducer.exchange_id_to_int(uncorrelated))
  meta.correlation |> should.equal(None)

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn invocation_started_metadata_test() {
  let label = "started"
  let #(attachment, started) =
    capture(telemetry.invocation_started_event(), label, fn(m) { m.listener })
  let config = runtime.config() |> runtime.with_label(label)
  let #(rt, outputs) = start_collecting(sample_server(), config)
  let corr = correlation.from_key("started-correlation")

  let exchange = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, exchange, "ctx", greet_frame("s", "Ann"), Some(corr))
  let meta = expect_event(started)
  meta.exchange_id |> should.equal(reducer.exchange_id_to_int(exchange))
  meta.method |> should.equal("tools/call")
  meta.tool |> should.equal(Some("greet"))
  meta.correlation |> should.equal(Some(corr))
  meta.listener |> should.equal(Some(label))
  let _ = expect_write(outputs, exchange)

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn invocation_completed_status_test() {
  let label = "completed"
  let #(attachment, completed) =
    capture(telemetry.invocation_completed_event(), label, fn(m) { m.listener })
  let config = runtime.config() |> runtime.with_label(label)
  let #(rt, outputs) = start_collecting(sample_server(), config)
  let corr = correlation.from_key("completed-correlation")

  let run = fn(id, tool_name, args) {
    let exchange = reducer.new_exchange_id()
    let assert Ok(Nil) =
      runtime.send_frame(
        rt,
        exchange,
        "ctx",
        call_frame(id, tool_name, args),
        Some(corr),
      )
    let _ = expect_write(outputs, exchange)
    expect_close(outputs, exchange)
    let assert Ok(#(measured, meta)) = process.receive(completed, 1000)
    let telemetry.InvocationCompletedMeasurements(duration_ms) = measured
    { duration_ms >= 0 } |> should.be_true
    meta.exchange_id |> should.equal(reducer.exchange_id_to_int(exchange))
    meta.method |> should.equal("tools/call")
    meta.tool |> should.equal(Some(tool_name))
    meta.correlation |> should.equal(Some(corr))
    meta.status
  }
  let named = json.object([#("name", json.string("Bo"))])

  run("ok", "greet", named) |> should.equal(telemetry.Succeeded)
  run("tool-failed", "fail", named) |> should.equal(telemetry.ToolFailed)
  run("input", "ask", named) |> should.equal(telemetry.InputRequested)
  run("bad-args", "greet", json.object([#("name", json.int(5))]))
  |> should.equal(telemetry.Failed)

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn exchange_closed_telemetry_carries_label_test() {
  let label = "closed"
  let #(attachment, closed) =
    capture(telemetry.exchange_closed_event(), label, fn(m) { m.listener })
  let config = runtime.config() |> runtime.with_label(label)
  let #(rt, _outputs) = start_collecting(sample_server(), config)

  let exchange = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, exchange, "ctx", discover_frame("c"), None)
  expect_event(closed)
  |> should.equal(telemetry.ExchangeClosedMeta(
    exchange_id: reducer.exchange_id_to_int(exchange),
    listener: Some(label),
  ))

  runtime.stop(rt)
  let assert Ok(Nil) = sinal.detach(attachment)
}

// --- live server changes -----------------------------------------------------

pub fn notify_and_tool_changes_reach_listen_stream_test() {
  let #(rt, outputs) = start_collecting(sample_server(), runtime.config())

  let stream = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(rt, stream, "ctx", listen_frame("listen-1"), None)
  expect_write(outputs, stream)
  |> string.contains("notifications/subscriptions/acknowledged")
  |> should.be_true

  runtime.notify(rt, subscriptions.ToolsListChanged)
  expect_write(outputs, stream)
  |> string.contains("notifications/tools/list_changed")
  |> should.be_true

  // The stream did not ask for prompt changes: nothing is written for them.
  runtime.notify(rt, subscriptions.PromptsListChanged)
  runtime.register_tool(rt, extra_tool())
  expect_write(outputs, stream)
  |> string.contains("notifications/tools/list_changed")
  |> should.be_true

  // A duplicate registration is ignored and announces nothing.
  runtime.register_tool(rt, extra_tool())
  let call = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      call,
      "ctx",
      call_frame("x1", "extra", json.object([])),
      None,
    )
  expect_write(outputs, call)
  |> structured_greeting
  |> should.equal("extra ran")
  expect_close(outputs, call)

  runtime.unregister_tool(rt, "extra")
  expect_write(outputs, stream)
  |> string.contains("notifications/tools/list_changed")
  |> should.be_true
  // Removing an absent tool announces nothing.
  runtime.unregister_tool(rt, "extra")
  let gone = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      gone,
      "ctx",
      call_frame("x2", "extra", json.object([])),
      None,
    )
  expect_write(outputs, gone) |> error_code |> should.equal(-32_602)
  expect_close(outputs, gone)

  runtime.end_streams(rt)
  let ended = expect_write(outputs, stream)
  let assert Ok(#(id, result_type)) =
    json.parse(ended, {
      use id <- decode.field("id", decode.string)
      use result_type <- decode.subfield(
        ["result", "resultType"],
        decode.string,
      )
      decode.success(#(id, result_type))
    })
  #(id, result_type) |> should.equal(#("listen-1", "complete"))
  expect_close(outputs, stream)

  // The stream is gone: later notifications reach no one.
  runtime.notify(rt, subscriptions.ToolsListChanged)
  expect_silence(outputs, 50)

  runtime.stop(rt)
}

// --- supervision -------------------------------------------------------------

fn wait_for_restart(
  name: process.Name(message),
  previous: Pid,
  attempts: Int,
) -> Pid {
  case process.named(name) {
    Ok(pid) if pid != previous -> pid
    _ if attempts <= 0 -> panic as "the supervised runtime did not restart"
    _ -> {
      process.sleep(10)
      wait_for_restart(name, previous, attempts - 1)
    }
  }
}

pub fn supervised_runtime_restarts_with_fresh_state_test() {
  let name = process.new_name("relay_runtime_test")
  let outputs = process.new_subject()
  let spec =
    runtime.supervised(
      sample_server(),
      runtime.config(),
      fn(output) {
        process.send(outputs, output)
        Ok(Nil)
      },
      name,
    )
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start

  let rt = runtime.named(name)
  runtime.register_tool(rt, extra_tool())
  let first_call = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      first_call,
      "ctx",
      call_frame("e1", "extra", json.object([])),
      None,
    )
  expect_write(outputs, first_call)
  |> structured_greeting
  |> should.equal("extra ran")
  expect_close(outputs, first_call)

  let assert Ok(first) = process.named(name)
  process.kill(first)
  let _second = wait_for_restart(name, first, 100)

  // The restarted runtime starts from the server description: the tool
  // registered at run time is gone, and the old exchange id is new to it.
  let rt = runtime.named(name)
  let after = reducer.new_exchange_id()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      after,
      "ctx",
      call_frame("e2", "extra", json.object([])),
      None,
    )
  expect_write(outputs, after) |> error_code |> should.equal(-32_602)
  expect_close(outputs, after)
  let assert Ok(Nil) =
    runtime.send_frame(rt, first_call, "ctx", greet_frame("again", "Zed"), None)
  expect_write(outputs, first_call)
  |> structured_greeting
  |> should.equal("ctx: hello Zed")

  process.unlink(supervisor.pid)
  process.kill(supervisor.pid)
}

// --- progress ----------------------------------------------------------------

pub fn runtime_progress_backpressure_bounds_mailbox_test() {
  let notices = process.new_subject()
  let observations = process.new_subject()
  let gate = start_sink_gate()
  let burst =
    tool.define("progress_burst", codec.success(Nil), codec.success(Nil))
    |> tool.handle_call(fn(call, _input) {
      report_progress_burst(call, 1, 128)
      process.send(tool.context(call), ProgressBurstFinished)
      Ok(tool.complete(Nil))
    })
  let config = runtime.config() |> runtime.with_invocation_timeout(ms(5000))
  let assert Ok(rt) =
    runtime.start(server.new([burst]), config, fn(output) {
      case output {
        runtime.OutputClose(_) -> Ok(Nil)
        runtime.OutputWrite(_, _) -> {
          let hold =
            process.call_forever(gate, fn(reply) { DecideToHold(reply) })
          case hold {
            False -> Nil
            True -> {
              // Keep the writer parked while the producer has a chance to offer
              // the rest of its burst, then inspect the runtime owner's mailbox.
              process.sleep(100)
              let queued = ffi_mailbox_size(ffi_self())
              let release = process.new_subject()
              process.send(observations, #(queued, release))
              let _ = process.receive(release, 5000)
              Nil
            }
          }
          Ok(Nil)
        }
      }
    })
  let frame =
    request_frame(
      "progress-burst",
      "tools/call",
      [
        #("name", json.string("progress_burst")),
        #("arguments", json.object([])),
      ],
      [#("progressToken", json.int(1))],
    )
  let assert Ok(Nil) =
    runtime.send_frame(rt, reducer.new_exchange_id(), notices, frame, None)
  let assert Ok(#(queued, release)) = process.receive(observations, 3000)
  process.send(release, Nil)
  let assert Ok(ProgressBurstFinished) = process.receive(notices, 5000)
  runtime.stop(rt)
  stop_sink_gate(gate)
  should.be_true(queued <= 1)
}

fn report_progress_burst(
  call: tool.Call(context),
  current: Int,
  last: Int,
) -> Nil {
  case current > last {
    True -> Nil
    False -> {
      tool.report_progress(call, int.to_float(current), None, None)
      report_progress_burst(call, current + 1, last)
    }
  }
}

fn start_sink_gate() -> Subject(SinkGateMessage) {
  let ready = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      sink_gate_loop(subject, True)
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  subject
}

fn sink_gate_loop(subject: Subject(SinkGateMessage), first: Bool) -> Nil {
  case process.receive(subject, 10_000) {
    Error(_) -> Nil
    Ok(DecideToHold(reply)) -> {
      process.send(reply, first)
      sink_gate_loop(subject, False)
    }
    Ok(StopSinkGate(reply)) -> process.send(reply, Nil)
  }
}

fn stop_sink_gate(gate: Subject(SinkGateMessage)) -> Nil {
  let reply = process.new_subject()
  process.send(gate, StopSinkGate(reply))
  let _ = process.receive(reply, 1000)
  Nil
}
