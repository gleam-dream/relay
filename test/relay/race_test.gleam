import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/set
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import relay/reducer.{ExchangeClosed, Received}
import relay/reducer_support as support
import relay/runtime
import relay/server.{type Server}
import relay/test_codec
import relay/tool

fn send_output_to(
  subject: Subject(BitArray),
  output: runtime.Output,
) -> Result(Nil, Nil) {
  case output {
    runtime.OutputWrite(_, bytes) -> process.send(subject, bytes)
    runtime.OutputClose(_) -> Nil
  }
  Ok(Nil)
}

@external(erlang, "erlang", "self")
fn ffi_self() -> dynamic.Dynamic

@external(erlang, "relay_race_ffi", "drain")
fn drain() -> Nil

@external(erlang, "relay_ffi", "mailbox_size")
fn ffi_mailbox_size(pid: dynamic.Dynamic) -> Int

fn repeat(times: Int, f: fn(Int) -> Nil) -> Nil {
  case times <= 0 {
    True -> Nil
    False -> {
      f(times)
      repeat(times - 1, f)
    }
  }
}

fn echo_server() -> Server(String) {
  server.new([
    tool.define(
      "echo",
      test_codec.property("val", codec.string()),
      codec.string(),
    )
    |> tool.with_description("Echoes")
    |> tool.handle(fn(val: String) { Ok(val) }),
  ])
}

fn slow_server(delay_ms: Int) -> Server(String) {
  server.new([
    tool.define(
      "slow_tool",
      test_codec.property("val", codec.string()),
      codec.string(),
    )
    |> tool.with_description("Sleeps and echoes")
    |> tool.handle(fn(val: String) {
      process.sleep(delay_ms)
      Ok(val)
    }),
  ])
}

fn call_frame(id: String, tool: String, arg: String) -> BitArray {
  support.call(id, tool, [#("val", json.string(arg))])
}

fn start(
  srv: Server(String),
  config: runtime.Config,
) -> #(runtime.Runtime(String), Subject(BitArray)) {
  let box: Subject(BitArray) = process.new_subject()
  let assert Ok(rt) =
    runtime.start(srv, config, fn(output) { send_output_to(box, output) })
  #(rt, box)
}

fn send(rt: runtime.Runtime(String), frame: BitArray) -> Nil {
  let assert Ok(Nil) =
    runtime.send_frame(rt, reducer.new_exchange_id(), "ctx", frame, None)
  Nil
}

// 1. Equal wire ids on distinct exchanges (repeated 20 times)
pub fn equal_wire_ids_race_test() {
  drain()
  repeat(20, fn(iter) {
    let #(rt, box) = start(echo_server(), runtime.config())

    // Two requests with the identical wire id "same-id" on distinct exchanges.
    let first = "msg-1-" <> int.to_string(iter)
    let second = "msg-2-" <> int.to_string(iter)
    send(rt, call_frame("same-id", "echo", first))
    send(rt, call_frame("same-id", "echo", second))

    let assert Ok(resp1) = process.receive(box, 3000)
    let assert Ok(resp2) = process.receive(box, 3000)

    // Each exchange gets its own answer.
    [resp1, resp2]
    |> list.map(fn(bytes) {
      support.at(bytes, ["result", "structuredContent"], decode.string)
    })
    |> set.from_list
    |> should.equal(set.from_list([first, second]))

    runtime.close(rt)
    runtime.stop(rt)

    // The test process mailbox is clean.
    ffi_mailbox_size(ffi_self()) |> should.equal(0)
  })
}

// 2. Duplicate admission on the same exchange in the pure reducer
pub fn duplicate_admission_race_test() {
  let s0 = reducer.init(echo_server())
  let ex = reducer.new_exchange_id()
  let frame = call_frame("dup-adm", "echo", "test")

  // The first message is admitted.
  let #(s1, eff1) = reducer.step(s0, Received(ex, "ctx", frame, None))
  list.length(eff1) |> should.equal(2)

  // A second message on the same exchange while the first is pending is
  // discarded without an invocation.
  let #(_s2, eff2) = reducer.step(s1, Received(ex, "ctx", frame, None))
  eff2 |> should.equal([])
}

// 3. Cancel before start
pub fn cancel_before_start_race_test() {
  let #(rt, box) = start(echo_server(), runtime.config())

  // A cancellation for a request that never started.
  send(rt, support.cancel("non-existent-id"))

  // A cancellation notification produces no wire response.
  process.receive(box, 200) |> should.be_error()

  runtime.close(rt)
  runtime.stop(rt)
}

// 4. Cancel racing completion (repeated 20 times)
pub fn cancel_racing_completion_test() {
  drain()
  repeat(20, fn(iter) {
    // The tool sleeps briefly so the cancellation arrives while it runs.
    let #(rt, box) = start(slow_server(30), runtime.config())

    let req_id = "race-cancel-" <> int.to_string(iter)
    send(rt, call_frame(req_id, "slow_tool", "fast"))
    send(rt, support.cancel(req_id))

    // Either the cancellation wins (no output) or the completion wins (one
    // output), but never two outputs.
    case process.receive(box, 300) {
      Ok(_) -> process.receive(box, 150) |> should.be_error()
      Error(_) -> Nil
    }

    runtime.close(rt)
    runtime.stop(rt)

    ffi_mailbox_size(ffi_self()) |> should.equal(0)
  })
}

// 5. Late completion after cancel
pub fn late_completion_after_cancel_test() {
  drain()
  let #(rt, box) = start(slow_server(100), runtime.config())

  send(rt, call_frame("late-cancel", "slow_tool", "sleepy"))

  // Cancel after 10 ms, then wait past the 100 ms handler runtime.
  process.sleep(10)
  send(rt, support.cancel("late-cancel"))
  process.sleep(150)

  // The late completion was suppressed.
  process.receive(box, 200) |> should.be_error()

  runtime.close(rt)
  runtime.stop(rt)

  ffi_mailbox_size(ffi_self()) |> should.equal(0)
}

// 6. Stale callback after owner replacement
pub fn stale_callback_after_owner_replacement_test() {
  drain()
  let srv = slow_server(150)
  let box: Subject(BitArray) = process.new_subject()
  let sink = fn(output) { send_output_to(box, output) }

  let assert Ok(rt1) = runtime.start(srv, runtime.config(), sink)
  send(rt1, call_frame("stale-1", "slow_tool", "data"))

  // Close and stop owner 1 while the invocation runs.
  runtime.close(rt1)
  runtime.stop(rt1)

  // Start owner 2 on the same sink.
  let assert Ok(rt2) = runtime.start(srv, runtime.config(), sink)

  // Wait until owner 1's invocation would have finished.
  process.sleep(200)

  // No stale message leaked into the sink from the stopped owner.
  process.receive(box, 100) |> should.be_error()

  runtime.close(rt2)
  runtime.stop(rt2)

  ffi_mailbox_size(ffi_self()) |> should.equal(0)
}

// 7. Simultaneous handler completion (repeated 5 times)
pub fn simultaneous_handler_completion_test() {
  drain()
  repeat(5, fn(iter) {
    let config =
      runtime.config()
      |> runtime.with_max_frame_bytes(65_536)
      |> runtime.with_max_live_exchanges(100)
      |> runtime.with_invocation_timeout(duration.seconds(5))
      |> runtime.with_tombstone_retention(duration.seconds(10))
    let #(rt, box) = start(echo_server(), config)

    // Dispatch 10 concurrent requests.
    let ids =
      list.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], fn(i) {
        let id = "sim-" <> int.to_string(iter) <> "-" <> int.to_string(i)
        send(rt, call_frame(id, "echo", id))
        id
      })

    // All 10 complete with distinct responses.
    list.map(ids, fn(_) {
      let assert Ok(resp) = process.receive(box, 3000)
      support.at(resp, ["id"], decode.string)
    })
    |> set.from_list
    |> should.equal(set.from_list(ids))

    runtime.close(rt)
    runtime.stop(rt)

    ffi_mailbox_size(ffi_self()) |> should.equal(0)
  })
}

// 8. Repeated close idempotency
pub fn repeated_close_idempotency_test() {
  let #(rt, _box) = start(echo_server(), runtime.config())

  // Repeated runtime close calls.
  runtime.close(rt)
  runtime.close(rt)
  runtime.close(rt)

  // A frame after close fails cleanly.
  runtime.send_frame(
    rt,
    reducer.new_exchange_id(),
    "ctx",
    call_frame("after-close", "echo", "hi"),
    None,
  )
  |> should.equal(Error(runtime.RuntimeStopped))

  // A repeated close in the pure reducer is idempotent too.
  let ex = reducer.new_exchange_id()
  let s0 = reducer.init(echo_server())
  let #(s1, eff1) = reducer.step(s0, ExchangeClosed(ex))
  eff1 |> should.equal([])
  let #(_s2, eff2) = reducer.step(s1, ExchangeClosed(ex))
  eff2 |> should.equal([])

  runtime.stop(rt)
}
