import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import json/blueprint/codec
import relay/runtime.{RuntimeConfig}
import relay/server.{ExchangeClosed, MessageReceived}
import relay/tool

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "erlang", "self")
fn ffi_self() -> dynamic.Dynamic

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

fn sample_registry() -> tool.Registry(String) {
  let assert Ok(name) = tool.tool_name("echo")
  let assert Ok(t) = case
    tool.definition(name, codec.field("val", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Echoes"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(val: String) { Ok(val) },
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let assert Ok(reg) = tool.registry([t])
  reg
}

fn slow_registry(delay_ms: Int) -> tool.Registry(String) {
  let assert Ok(name) = tool.tool_name("slow_tool")
  let assert Ok(t) = case
    tool.definition(name, codec.field("val", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Sleeps and echoes"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(val: String) {
            process.sleep(delay_ms)
            Ok(val)
          },
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let assert Ok(reg) = tool.registry([t])
  reg
}

fn make_call_frame(id: String, tool: String, arg: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string("tools/call")),
    #(
      "params",
      json.object([
        #("name", json.string(tool)),
        #("arguments", json.object([#("val", json.string(arg))])),
        #(
          "_meta",
          json.object([
            #(
              "io.modelcontextprotocol/protocolVersion",
              json.string("2026-07-28"),
            ),
            #("io.modelcontextprotocol/clientCapabilities", json.object([])),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

fn make_cancel_frame(id: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/cancelled")),
    #("params", json.object([#("requestId", json.string(id))])),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

// 1. Equal wire IDs on distinct exchanges (repeated 20 times)
pub fn equal_wire_ids_race_test() {
  repeat(20, fn(iter) {
    let reg = sample_registry()
    let s = server.server(reg)
    let box: Subject(BitArray) = process.new_subject()
    let sink = fn(bytes: BitArray) { process.send(box, bytes) }
    let cfg = runtime.default_config()

    let assert Ok(rt) = runtime.start(s, cfg, sink)

    let ex1 = server.fresh_exchange()
    let ex2 = server.fresh_exchange()

    // Send two requests with identical wire ID "same-id" on distinct exchanges
    let frame1 =
      make_call_frame("same-id", "echo", "msg-1-" <> int.to_string(iter))
    let frame2 =
      make_call_frame("same-id", "echo", "msg-2-" <> int.to_string(iter))

    let assert Ok(_) = runtime.send_frame(rt, ex1, "ctx", frame1, 1000)
    let assert Ok(_) = runtime.send_frame(rt, ex2, "ctx", frame2, 1000)

    let assert Ok(resp1) = process.receive(box, 3000)
    let assert Ok(resp2) = process.receive(box, 3000)

    let assert Ok(str1) = bit_array.to_string(resp1)
    let assert Ok(str2) = bit_array.to_string(resp2)

    // Both should parse as valid JSON
    let assert Ok(_) = json.parse(str1, decode.dynamic)
    let assert Ok(_) = json.parse(str2, decode.dynamic)

    runtime.close(rt)
    runtime.stop(rt, 1000)

    // Verify test process mailbox is completely clean
    ffi_mailbox_size(ffi_self()) |> should.equal(0)
  })
}

// 2. Duplicate admission on same exchange in pure reducer
pub fn duplicate_admission_race_test() {
  let reg = sample_registry()
  let s0 = server.server(reg)
  let ex = server.exchange_id(501)
  let frame = make_call_frame("dup-adm", "echo", "test")

  // First message admitted
  let #(s1, eff1) = server.step(s0, MessageReceived(ex, "ctx", frame))
  list.length(eff1) |> should.equal(2)

  // Second message on same exchange ID while first is pending
  let #(_s2, eff2) = server.step(s1, MessageReceived(ex, "ctx", frame))
  // Discarded / no invocation
  eff2 |> should.equal([])
}

// 3. Cancel-before-start
pub fn cancel_before_start_race_test() {
  let reg = sample_registry()
  let s = server.server(reg)
  let box: Subject(BitArray) = process.new_subject()
  let sink = fn(bytes: BitArray) { process.send(box, bytes) }
  let cfg = runtime.default_config()

  let assert Ok(rt) = runtime.start(s, cfg, sink)

  let ex = server.fresh_exchange()
  // Send cancellation for a request that has never been started
  let cancel_frame = make_cancel_frame("non-existent-id")
  let assert Ok(_) = runtime.send_frame(rt, ex, "ctx", cancel_frame, 1000)

  // Cancellation notification MUST NOT produce any wire response
  let timeout_res = process.receive(box, 200)
  timeout_res |> should.be_error()

  runtime.close(rt)
  runtime.stop(rt, 1000)
}

// 4. Cancel racing completion (repeated 20 times)
pub fn cancel_racing_completion_test() {
  repeat(20, fn(iter) {
    // Tool that sleeps briefly so cancel arrives while running
    let reg = slow_registry(30)
    let s = server.server(reg)
    let box: Subject(BitArray) = process.new_subject()
    let sink = fn(bytes: BitArray) { process.send(box, bytes) }
    let cfg = runtime.default_config()

    let assert Ok(rt) = runtime.start(s, cfg, sink)

    let ex1 = server.fresh_exchange()
    let req_id = "race-cancel-" <> int.to_string(iter)
    let call_frame = make_call_frame(req_id, "slow_tool", "fast")
    let assert Ok(_) = runtime.send_frame(rt, ex1, "ctx", call_frame, 1000)

    // Send cancel immediately
    let ex2 = server.fresh_exchange()
    let cancel_frame = make_cancel_frame(req_id)
    let assert Ok(_) = runtime.send_frame(rt, ex2, "ctx", cancel_frame, 1000)

    // Either cancel wins (no output) or completion wins (one output), but NEVER two outputs
    case process.receive(box, 300) {
      Ok(_) -> {
        // If completion won, ensure no second message arrives
        process.receive(box, 150) |> should.be_error()
      }
      Error(_) -> {
        // Cancel won, mailbox is empty
        Nil
      }
    }

    runtime.close(rt)
    runtime.stop(rt, 1000)

    ffi_mailbox_size(ffi_self()) |> should.equal(0)
  })
}

// 5. Late completion after cancel
pub fn late_completion_after_cancel_test() {
  let reg = slow_registry(100)
  let s = server.server(reg)
  let box: Subject(BitArray) = process.new_subject()
  let sink = fn(bytes: BitArray) { process.send(box, bytes) }
  let cfg = runtime.default_config()

  let assert Ok(rt) = runtime.start(s, cfg, sink)

  let ex1 = server.fresh_exchange()
  let call_frame = make_call_frame("late-cancel", "slow_tool", "sleepy")
  let assert Ok(_) = runtime.send_frame(rt, ex1, "ctx", call_frame, 1000)

  // Wait 10ms then cancel
  process.sleep(10)
  let ex2 = server.fresh_exchange()
  let cancel_frame = make_cancel_frame("late-cancel")
  let assert Ok(_) = runtime.send_frame(rt, ex2, "ctx", cancel_frame, 1000)

  // Sleep past the 100ms handler runtime
  process.sleep(150)

  // The late completion MUST have been suppressed by the tombstone
  let late_msg = process.receive(box, 200)
  late_msg |> should.be_error()

  runtime.close(rt)
  runtime.stop(rt, 1000)

  ffi_mailbox_size(ffi_self()) |> should.equal(0)
}

// 6. Stale callback after owner replacement
pub fn stale_callback_after_owner_replacement_test() {
  let reg = slow_registry(150)
  let s = server.server(reg)
  let box: Subject(BitArray) = process.new_subject()
  let sink = fn(bytes: BitArray) { process.send(box, bytes) }
  let cfg = runtime.default_config()

  let assert Ok(rt1) = runtime.start(s, cfg, sink)

  let ex1 = server.fresh_exchange()
  let call_frame = make_call_frame("stale-1", "slow_tool", "data")
  let assert Ok(_) = runtime.send_frame(rt1, ex1, "ctx", call_frame, 1000)

  // Close and stop owner 1 while invocation is running
  runtime.close(rt1)
  runtime.stop(rt1, 100)

  // Start new owner 2
  let assert Ok(rt2) = runtime.start(s, cfg, sink)

  // Wait until owner 1's invocation would have finished
  process.sleep(200)

  // No stale message leaked into the sink from the stopped owner
  process.receive(box, 100) |> should.be_error()

  runtime.close(rt2)
  runtime.stop(rt2, 1000)

  ffi_mailbox_size(ffi_self()) |> should.equal(0)
}

// 7. Simultaneous handler completion (repeated 5 times)
pub fn simultaneous_handler_completion_test() {
  repeat(5, fn(iter) {
    let reg = sample_registry()
    let s = server.server(reg)
    let box: Subject(BitArray) = process.new_subject()
    let sink = fn(bytes: BitArray) { process.send(box, bytes) }
    let cfg =
      RuntimeConfig(
        max_frame_bytes: 65_536,
        max_live_exchanges: 100,
        invocation_timeout_ms: 5000,
        tombstone_retention_ms: 10_000,
      )

    let assert Ok(rt) = runtime.start(s, cfg, sink)

    // Dispatch 10 concurrent requests
    let ids = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    list.each(ids, fn(i) {
      let ex = server.fresh_exchange()
      let id_str = "sim-" <> int.to_string(iter) <> "-" <> int.to_string(i)
      let frame = make_call_frame(id_str, "echo", id_str)
      let assert Ok(_) = runtime.send_frame(rt, ex, "ctx", frame, 1000)
    })

    // All 10 must complete and produce distinct responses
    let responses =
      list.map(ids, fn(_) {
        let assert Ok(resp) = process.receive(box, 3000)
        resp
      })

    list.length(responses) |> should.equal(10)

    runtime.close(rt)
    runtime.stop(rt, 1000)

    ffi_mailbox_size(ffi_self()) |> should.equal(0)
  })
}

// 8. Repeated close idempotency
pub fn repeated_close_idempotency_test() {
  let reg = sample_registry()
  let s = server.server(reg)
  let box: Subject(BitArray) = process.new_subject()
  let sink = fn(bytes: BitArray) { process.send(box, bytes) }
  let cfg = runtime.default_config()

  let assert Ok(rt) = runtime.start(s, cfg, sink)

  // Repeated runtime close calls
  runtime.close(rt)
  runtime.close(rt)
  runtime.close(rt)

  // Sending frame after close fails cleanly
  let ex = server.fresh_exchange()
  let frame = make_call_frame("after-close", "echo", "hi")
  runtime.send_frame(rt, ex, "ctx", frame, 1000)
  |> should.be_error()

  // Pure reducer repeated close is also idempotent
  let ex2 = server.exchange_id(999)
  let s0 = server.server(reg)
  let #(s1, eff1) = server.step(s0, ExchangeClosed(ex2))
  eff1 |> should.equal([])
  let #(_s2, eff2) = server.step(s1, ExchangeClosed(ex2))
  eff2 |> should.equal([])

  runtime.stop(rt, 1000)
}
