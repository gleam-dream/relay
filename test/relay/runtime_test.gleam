import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import relay
import relay/runtime.{RuntimeConfig}
import relay/server

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_server() -> server.Server(String) {
  let assert Ok(greet_name) = relay.tool_name("greet")
  let assert Ok(greet_tool) =
    relay.context_tool(
      greet_name,
      relay.tool_metadata("Greets a user"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(ctx: String, user: String) { Ok(ctx <> ": hello " <> user) },
    )

  let assert Ok(crash_name) = relay.tool_name("crash")
  let assert Ok(crash_tool) =
    relay.context_tool(
      crash_name,
      relay.tool_metadata("Always crashes"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: String, _user: String) {
        panic as "Deliberate handler crash for testing"
      },
    )

  let assert Ok(slow_name) = relay.tool_name("slow")
  let assert Ok(slow_tool) =
    relay.context_tool(
      slow_name,
      relay.tool_metadata("Slow handler"),
      codec.field("ms", codec.int()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: String, ms: Int) {
        process.sleep(ms)
        Ok("finished slow")
      },
    )

  let assert Ok(reg) = relay.registry([greet_tool, crash_tool, slow_tool])
  server.server(reg)
}

fn make_discover_frame(id: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string("server/discover")),
    #(
      "params",
      json.object([
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

fn make_call_frame(id: String, tool_name: String, args: json.Json) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string("tools/call")),
    #(
      "params",
      json.object([
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
        #("name", json.string(tool_name)),
        #("arguments", args),
      ]),
    ),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

pub fn runtime_lifecycle_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(bytes) { process.send(sink_subj, bytes) })

  // 1. Discover
  let ex1 = server.fresh_exchange()
  let assert Ok(Nil) =
    runtime.send_frame(rt, ex1, "test_ctx", make_discover_frame("disc-1"), 1000)

  let assert Ok(out1) = process.receive(sink_subj, 1000)
  let assert Ok(str1) = bit_array.to_string(out1)
  let assert Ok(json1) = json.parse(str1, decode.dynamic)
  let assert Ok(dict1) =
    decode.run(json1, decode.dict(decode.string, decode.dynamic))
  let assert Ok(_) = dict.get(dict1, "result")

  // 2. Tools call
  let ex2 = server.fresh_exchange()
  let call_frame =
    make_call_frame(
      "call-1",
      "greet",
      json.object([#("name", json.string("Alice"))]),
    )
  let assert Ok(Nil) = runtime.send_frame(rt, ex2, "my_ctx", call_frame, 1000)

  let assert Ok(out2) = process.receive(sink_subj, 1000)
  let assert Ok(str2) = bit_array.to_string(out2)
  let assert Ok(json2) = json.parse(str2, decode.dynamic)
  let assert Ok(dict2) =
    decode.run(json2, decode.dict(decode.string, decode.dynamic))
  let assert Ok(res2_dyn) = dict.get(dict2, "result")
  let assert Ok(res2_dict) =
    decode.run(res2_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(struct_content) = dict.get(res2_dict, "structuredContent")
  let assert Ok(content_str) = decode.run(struct_content, decode.string)
  content_str |> should.equal("my_ctx: hello Alice")

  runtime.stop(rt, 1000)
}

pub fn runtime_crash_isolation_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(bytes) { process.send(sink_subj, bytes) })

  // Call the crashing tool
  let ex = server.fresh_exchange()
  let call_crash =
    make_call_frame(
      "crash-1",
      "crash",
      json.object([#("name", json.string("test"))]),
    )
  let assert Ok(Nil) = runtime.send_frame(rt, ex, "ctx", call_crash, 1000)

  // Expect sanitized internal error (-32603)
  let assert Ok(out) = process.receive(sink_subj, 1000)
  let assert Ok(str) = bit_array.to_string(out)
  let assert Ok(parsed) = json.parse(str, decode.dynamic)
  let assert Ok(d) =
    decode.run(parsed, decode.dict(decode.string, decode.dynamic))
  let assert Ok(err_dyn) = dict.get(d, "error")
  let assert Ok(err_dict) =
    decode.run(err_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(code_dyn) = dict.get(err_dict, "code")
  let assert Ok(code) = decode.run(code_dyn, decode.int)
  code |> should.equal(-32_603)

  // Verify owner is still alive and responds to normal requests
  let ex_alive = server.fresh_exchange()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      ex_alive,
      "ctx",
      make_discover_frame("alive-1"),
      1000,
    )
  let assert Ok(out_alive) = process.receive(sink_subj, 1000)
  let assert Ok(str_alive) = bit_array.to_string(out_alive)
  let assert Ok(parsed_alive) = json.parse(str_alive, decode.dynamic)
  let assert Ok(dict_alive) =
    decode.run(parsed_alive, decode.dict(decode.string, decode.dynamic))
  let assert Ok(_) = dict.get(dict_alive, "result")

  runtime.stop(rt, 1000)
}

pub fn runtime_timeout_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  // Short timeout: 50ms
  let config =
    RuntimeConfig(
      max_live_exchanges: 10,
      max_frame_bytes: 1024,
      invocation_timeout_ms: 50,
      tombstone_retention_ms: 1000,
    )

  let assert Ok(rt) =
    runtime.start(s, config, fn(bytes) { process.send(sink_subj, bytes) })

  // Call slow tool for 300ms
  let ex = server.fresh_exchange()
  let call_slow =
    make_call_frame("slow-1", "slow", json.object([#("ms", json.int(300))]))
  let assert Ok(Nil) = runtime.send_frame(rt, ex, "ctx", call_slow, 1000)

  // Expect internal error (-32603) from timeout
  let assert Ok(out) = process.receive(sink_subj, 1000)
  let assert Ok(str) = bit_array.to_string(out)
  let assert Ok(parsed) = json.parse(str, decode.dynamic)
  let assert Ok(d) =
    decode.run(parsed, decode.dict(decode.string, decode.dynamic))
  let assert Ok(err_dyn) = dict.get(d, "error")
  let assert Ok(err_dict) =
    decode.run(err_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(code_dyn) = dict.get(err_dict, "code")
  let assert Ok(code) = decode.run(code_dyn, decode.int)
  code |> should.equal(-32_603)

  runtime.stop(rt, 1000)
}

pub fn runtime_cancellation_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config =
    RuntimeConfig(
      max_live_exchanges: 10,
      max_frame_bytes: 1024,
      invocation_timeout_ms: 5000,
      tombstone_retention_ms: 1000,
    )

  let assert Ok(rt) =
    runtime.start(s, config, fn(bytes) { process.send(sink_subj, bytes) })

  // Start slow tool
  let ex1 = server.fresh_exchange()
  let call_slow =
    make_call_frame(
      "cancel-req-1",
      "slow",
      json.object([#("ms", json.int(300))]),
    )
  let assert Ok(Nil) = runtime.send_frame(rt, ex1, "ctx", call_slow, 1000)

  // Cancel it immediately
  let ex2 = server.fresh_exchange()
  let cancel_frame =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("notifications/cancelled")),
      #("params", json.object([#("requestId", json.string("cancel-req-1"))])),
    ])
    |> json.to_string()
    |> bit_array.from_string()

  let assert Ok(Nil) = runtime.send_frame(rt, ex2, "ctx", cancel_frame, 1000)

  // Wait 400ms: ensure NO completion message is received for cancel-req-1!
  case process.receive(sink_subj, 400) {
    Ok(_) -> should.fail()
    Error(Nil) -> Nil
  }

  runtime.stop(rt, 1000)
}

pub fn runtime_frame_bound_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config =
    RuntimeConfig(
      max_live_exchanges: 10,
      max_frame_bytes: 20,
      // very small
      invocation_timeout_ms: 1000,
      tombstone_retention_ms: 1000,
    )

  let assert Ok(rt) =
    runtime.start(s, config, fn(bytes) { process.send(sink_subj, bytes) })

  let ex = server.fresh_exchange()
  let large_frame = make_discover_frame("large-1")
  let res = runtime.send_frame(rt, ex, "ctx", large_frame, 1000)
  case res {
    Error(runtime.FrameTooLarge(_, _)) -> Nil
    _ -> should.fail()
  }

  runtime.stop(rt, 1000)
}

pub fn runtime_equal_wire_ids_on_distinct_exchanges_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(bytes) { process.send(sink_subj, bytes) })

  // Two distinct exchanges with same JSON-RPC id: "same-id"
  let ex1 = server.fresh_exchange()
  let ex2 = server.fresh_exchange()

  let f1 =
    make_call_frame(
      "same-id",
      "greet",
      json.object([#("name", json.string("User1"))]),
    )
  let f2 =
    make_call_frame(
      "same-id",
      "greet",
      json.object([#("name", json.string("User2"))]),
    )

  let assert Ok(Nil) = runtime.send_frame(rt, ex1, "ctx1", f1, 1000)
  let assert Ok(Nil) = runtime.send_frame(rt, ex2, "ctx2", f2, 1000)

  let assert Ok(out1) = process.receive(sink_subj, 1000)
  let assert Ok(out2) = process.receive(sink_subj, 1000)

  let assert Ok(str1) = bit_array.to_string(out1)
  let assert Ok(str2) = bit_array.to_string(out2)

  // Both completed successfully
  let assert True =
    string.contains(str1, "User1") || string.contains(str2, "User1")
  let assert True =
    string.contains(str1, "User2") || string.contains(str2, "User2")

  runtime.stop(rt, 1000)
}

pub fn runtime_repeated_close_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(bytes) { process.send(sink_subj, bytes) })

  runtime.close(rt)
  runtime.close(rt)
  runtime.close(rt)

  // Subsequent frame submissions reject with RuntimeStopped
  let ex = server.fresh_exchange()
  let res = runtime.send_frame(rt, ex, "ctx", make_discover_frame("1"), 1000)
  res |> should.equal(Error(runtime.RuntimeStopped))

  runtime.stop(rt, 1000)
}
