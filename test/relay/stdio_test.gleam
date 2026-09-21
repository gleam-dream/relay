import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/string
import gleeunit
import gleeunit/should
import relay
import relay/runtime
import relay/server
import relay/transport/stdio.{Frame, FrameOversized, InvalidTrailingBytes}

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "relay_ffi", "spawn_stdio_child")
fn ffi_spawn_stdio_child(cmd: String) -> dynamic.Dynamic

@external(erlang, "relay_ffi", "spawn_stdio_child_closed_stdout")
fn ffi_spawn_stdio_child_closed_stdout(cmd: String) -> dynamic.Dynamic

@external(erlang, "relay_ffi", "send_to_child")
fn ffi_send_to_child(port: dynamic.Dynamic, bytes: BitArray) -> Nil

@external(erlang, "relay_ffi", "receive_from_child")
fn ffi_receive_from_child(
  port: dynamic.Dynamic,
  timeout_ms: Int,
) -> Result(BitArray, Nil)

@external(erlang, "relay_ffi", "receive_exit_status")
fn ffi_receive_exit_status(
  port: dynamic.Dynamic,
  timeout_ms: Int,
) -> Result(Int, Nil)

@external(erlang, "relay_ffi", "close_child")
fn ffi_close_child(port: dynamic.Dynamic) -> Nil

// 1. Framer Unit Tests

pub fn framer_single_frame_test() {
  let f0 = stdio.new_framer(1024)
  let chunk = bit_array.from_string("{\"jsonrpc\":\"2.0\"}\n")
  let #(f1, frames) = stdio.feed_framer(f0, chunk)

  case frames {
    [Frame(line)] -> {
      line |> should.equal(bit_array.from_string("{\"jsonrpc\":\"2.0\"}"))
    }
    _ -> should.fail()
  }

  let trailing = stdio.finish_framer(f1)
  trailing |> should.equal([])
}

pub fn framer_crlf_frame_test() {
  let f0 = stdio.new_framer(1024)
  let chunk = bit_array.from_string("{\"jsonrpc\":\"2.0\"}\r\n")
  let #(f1, frames) = stdio.feed_framer(f0, chunk)

  case frames {
    [Frame(line)] -> {
      line |> should.equal(bit_array.from_string("{\"jsonrpc\":\"2.0\"}"))
    }
    _ -> should.fail()
  }

  let trailing = stdio.finish_framer(f1)
  trailing |> should.equal([])
}

pub fn framer_multiple_frames_in_one_chunk_test() {
  let f0 = stdio.new_framer(1024)
  let chunk = bit_array.from_string("line1\nline2\nline3\n")
  let #(_f1, frames) = stdio.feed_framer(f0, chunk)

  case frames {
    [Frame(l1), Frame(l2), Frame(l3)] -> {
      l1 |> should.equal(bit_array.from_string("line1"))
      l2 |> should.equal(bit_array.from_string("line2"))
      l3 |> should.equal(bit_array.from_string("line3"))
    }
    _ -> should.fail()
  }
}

pub fn framer_partial_read_test() {
  let f0 = stdio.new_framer(1024)
  let chunk1 = bit_array.from_string("{\"jsonrpc\":")
  let #(f1, frames1) = stdio.feed_framer(f0, chunk1)
  frames1 |> should.equal([])

  let chunk2 = bit_array.from_string("\"2.0\"}\n")
  let #(f2, frames2) = stdio.feed_framer(f1, chunk2)

  case frames2 {
    [Frame(line)] -> {
      line |> should.equal(bit_array.from_string("{\"jsonrpc\":\"2.0\"}"))
    }
    _ -> should.fail()
  }

  stdio.finish_framer(f2) |> should.equal([])
}

pub fn framer_utf8_split_across_chunks_test() {
  let f0 = stdio.new_framer(1024)
  // "€" in UTF-8 is 3 bytes: 226, 130, 172
  let euro_p1 = <<226, 130>>
  let euro_p2 = <<172>>

  let chunk1 =
    bit_array.append(bit_array.from_string("{\"currency\":\""), euro_p1)
  let #(f1, frames1) = stdio.feed_framer(f0, chunk1)
  frames1 |> should.equal([])

  let chunk2 = bit_array.append(euro_p2, bit_array.from_string("\"}\n"))
  let #(_f2, frames2) = stdio.feed_framer(f1, chunk2)

  case frames2 {
    [Frame(line)] -> {
      let assert Ok(str) = bit_array.to_string(line)
      str |> should.equal("{\"currency\":\"€\"}")
    }
    _ -> should.fail()
  }
}

pub fn framer_oversized_frame_test() {
  let f0 = stdio.new_framer(10)
  // Limit is 10 bytes
  let chunk = bit_array.from_string("this is definitely longer than 10 bytes\n")
  let #(_f1, frames) = stdio.feed_framer(f0, chunk)

  case frames {
    [FrameOversized(size, limit)] -> {
      size |> should.equal(39)
      limit |> should.equal(10)
    }
    _ -> should.fail()
  }
}

pub fn framer_discards_the_remainder_of_an_oversized_frame_test() {
  let f0 = stdio.new_framer(3)
  let #(f1, first) = stdio.feed_framer(f0, bit_array.from_string("abcd"))
  first |> should.equal([FrameOversized(4, 3)])

  let #(f2, second) =
    stdio.feed_framer(f1, bit_array.from_string("discard this\nok\n"))
  second |> should.equal([Frame(bit_array.from_string("ok"))])
  stdio.finish_framer(f2) |> should.equal([])
}

pub fn framer_incomplete_eof_test() {
  let f0 = stdio.new_framer(1024)
  let chunk = bit_array.from_string("incomplete frame without newline")
  let #(f1, frames) = stdio.feed_framer(f0, chunk)
  frames |> should.equal([])

  let trailing = stdio.finish_framer(f1)
  case trailing {
    [InvalidTrailingBytes(rem)] -> {
      rem
      |> should.equal(bit_array.from_string("incomplete frame without newline"))
    }
    _ -> should.fail()
  }
}

pub fn writer_failure_is_returned_as_a_typed_terminal_error_test() {
  let assert Ok(writer) =
    stdio.start_writer(fn(_bytes) { Error(stdio.StdoutBroken("closed pipe")) })

  stdio.write_bytes(writer, bit_array.from_string("response\n"))
  |> should.equal(Error(stdio.StdoutBroken("closed pipe")))

  stdio.stop_writer(writer)
}

pub fn oversized_frame_refusal_write_failure_stops_the_stream_test() {
  let assert Ok(registry) = relay.registry([])
  let assert Ok(rt) =
    runtime.start(server.server(registry), runtime.default_config(), fn(_bytes) {
      Nil
    })
  let assert Ok(writer) =
    stdio.start_writer(fn(_bytes) { Error(stdio.StdoutBroken("closed pipe")) })
  let reader = fn() { stdio.ReadChunk(bit_array.from_string("too-long\n")) }

  stdio.stream_read_loop(rt, Nil, reader, writer, stdio.new_framer(4), 1000)
  |> should.equal(Error(stdio.StdoutBroken("closed pipe")))

  runtime.stop(rt, 1000)
  stdio.stop_writer(writer)
}

// 2. Real Spawned Child Process Tests over OS Pipes

pub fn spawned_child_stdio_server_test() {
  // Command running our compiled child server
  let cmd =
    "erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main"
  let child = ffi_spawn_stdio_child(cmd)

  // 1. Send server/discover
  let disc_req =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("disc-child-1")),
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

  ffi_send_to_child(child, bit_array.from_string(disc_req <> "\n"))

  let assert Ok(resp1_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(resp1_str) = bit_array.to_string(resp1_bytes)
  let assert Ok(json1) = json.parse(resp1_str, decode.dynamic)
  let assert Ok(dict1) =
    decode.run(json1, decode.dict(decode.string, decode.dynamic))
  let assert Ok(res1_dyn) = dict.get(dict1, "result")
  let assert Ok(res1_dict) =
    decode.run(res1_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(meta_dyn) = dict.get(res1_dict, "_meta")
  let assert Ok(meta_dict) =
    decode.run(meta_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(server_info) =
    dict.get(meta_dict, "io.modelcontextprotocol/serverInfo")
  let assert Ok(server_info_dict) =
    decode.run(server_info, decode.dict(decode.string, decode.string))
  let assert Ok(name) = dict.get(server_info_dict, "name")
  name |> should.equal("relay")

  // 2. Send tools/list
  let list_req =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(10)),
      #("method", json.string("tools/list")),
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

  ffi_send_to_child(child, bit_array.from_string(list_req <> "\n"))

  let assert Ok(resp2_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(resp2_str) = bit_array.to_string(resp2_bytes)
  let assert Ok(json2) = json.parse(resp2_str, decode.dynamic)
  let assert Ok(dict2) =
    decode.run(json2, decode.dict(decode.string, decode.dynamic))
  let assert Ok(_) = dict.get(dict2, "result")

  // 3. Send tools/call for greet (success)
  let call_req =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("call-greet")),
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
          #("name", json.string("greet")),
          #("arguments", json.object([#("name", json.string("Bob"))])),
        ]),
      ),
    ])
    |> json.to_string()

  ffi_send_to_child(child, bit_array.from_string(call_req <> "\n"))

  let assert Ok(resp3_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(resp3_str) = bit_array.to_string(resp3_bytes)
  let assert Ok(json3) = json.parse(resp3_str, decode.dynamic)
  let assert Ok(dict3) =
    decode.run(json3, decode.dict(decode.string, decode.dynamic))
  let assert Ok(res3_dyn) = dict.get(dict3, "result")
  let assert Ok(res3_dict) =
    decode.run(res3_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(struct3) = dict.get(res3_dict, "structuredContent")
  let assert Ok(text3) = decode.run(struct3, decode.string)
  text3 |> should.equal("child-server: hello Bob")

  // 4. Send tools/call for fail_tool (tool application error)
  let fail_req =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("call-fail")),
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
          #("name", json.string("fail_tool")),
          #("arguments", json.object([#("msg", json.string("boom"))])),
        ]),
      ),
    ])
    |> json.to_string()

  ffi_send_to_child(child, bit_array.from_string(fail_req <> "\n"))

  let assert Ok(resp4_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(resp4_str) = bit_array.to_string(resp4_bytes)
  let assert Ok(json4) = json.parse(resp4_str, decode.dynamic)
  let assert Ok(dict4) =
    decode.run(json4, decode.dict(decode.string, decode.dynamic))
  let assert Ok(res4_dyn) = dict.get(dict4, "result")
  let assert Ok(res4_dict) =
    decode.run(res4_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(is_err_dyn) = dict.get(res4_dict, "isError")
  let assert Ok(is_err) = decode.run(is_err_dyn, decode.bool)
  is_err |> should.equal(True)

  // Close child cleanly
  ffi_close_child(child)
}

pub fn asynchronous_broken_stdout_stops_with_idle_stdin_test() {
  let cmd =
    "erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main"
  let child = ffi_spawn_stdio_child_closed_stdout(cmd)
  let request =
    "{\"jsonrpc\":\"2.0\",\"id\":\"slow-pipe\",\"method\":\"tools/call\","
    <> "\"params\":{\"_meta\":{"
    <> "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\","
    <> "\"io.modelcontextprotocol/clientCapabilities\":{}},"
    <> "\"name\":\"slow\",\"arguments\":{\"ms\":150}}}\n"
  ffi_send_to_child(child, bit_array.from_string(request))

  // Keep the input pipe open while the delayed handler attempts its response.
  case ffi_receive_exit_status(child, 1500) {
    Ok(status) -> {
      ffi_close_child(child)
      status |> should.equal(1)
    }
    Error(_) -> {
      // Release the child input only after the bounded assertion window so a
      // failed implementation does not leave a child process behind.
      ffi_send_to_child(child, bit_array.from_string("close\n"))
      let _ = ffi_receive_exit_status(child, 2000)
      ffi_close_child(child)
      should.fail()
    }
  }
}

pub fn spawned_child_partial_utf8_across_chunks_test() {
  let cmd =
    "erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main"
  let child = ffi_spawn_stdio_child(cmd)

  // Greet tool call containing multi-byte UTF-8 character "€" (3 bytes: 226, 130, 172)
  // Part 1: up to first 2 bytes of "€"
  let p1 =
    bit_array.concat([
      bit_array.from_string(
        "{\"jsonrpc\":\"2.0\",\"id\":\"split-utf8\",\"method\":\"tools/call\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}},\"name\":\"greet\",\"arguments\":{\"name\":\"",
      ),
      <<226, 130>>,
    ])
  // Part 2: 3rd byte of "€" and remainder of frame
  let p2 =
    bit_array.concat([
      <<172>>,
      bit_array.from_string("\"}}}\n"),
    ])

  // Send chunk 1
  ffi_send_to_child(child, p1)
  // Send chunk 2
  ffi_send_to_child(child, p2)

  let assert Ok(resp_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(resp_str) = bit_array.to_string(resp_bytes)
  let assert Ok(json_val) = json.parse(resp_str, decode.dynamic)
  let assert Ok(dict_val) =
    decode.run(json_val, decode.dict(decode.string, decode.dynamic))
  let assert Ok(res_dyn) = dict.get(dict_val, "result")
  let assert Ok(res_dict) =
    decode.run(res_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(struct_val) = dict.get(res_dict, "structuredContent")
  let assert Ok(text) = decode.run(struct_val, decode.string)
  text |> should.equal("child-server: hello €")

  ffi_close_child(child)
}

pub fn spawned_child_multi_frame_chunk_test() {
  let cmd =
    "erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main"
  let child = ffi_spawn_stdio_child(cmd)

  let f1 =
    "{\"jsonrpc\":\"2.0\",\"id\":\"multi-1\",\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n"
  let f2 =
    "{\"jsonrpc\":\"2.0\",\"id\":\"multi-2\",\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n"

  // Send both frames in one OS chunk
  ffi_send_to_child(child, bit_array.from_string(f1 <> f2))

  // Receive response 1
  let assert Ok(resp1_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(resp1_str) = bit_array.to_string(resp1_bytes)
  let assert Ok(json1) = json.parse(resp1_str, decode.dynamic)
  let assert Ok(dict1) =
    decode.run(json1, decode.dict(decode.string, decode.dynamic))
  let assert Ok(id1) = dict.get(dict1, "id")
  let assert Ok(id1_str) = decode.run(id1, decode.string)
  id1_str |> should.equal("multi-1")

  // Receive response 2
  let assert Ok(resp2_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(resp2_str) = bit_array.to_string(resp2_bytes)
  let assert Ok(json2) = json.parse(resp2_str, decode.dynamic)
  let assert Ok(dict2) =
    decode.run(json2, decode.dict(decode.string, decode.dynamic))
  let assert Ok(id2) = dict.get(dict2, "id")
  let assert Ok(id2_str) = decode.run(id2, decode.string)
  id2_str |> should.equal("multi-2")

  ffi_close_child(child)
}

pub fn spawned_child_eof_clean_shutdown_test() {
  let cmd =
    "erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main </dev/null"
  let child = ffi_spawn_stdio_child(cmd)

  // A real /dev/null stdin reaches the server as clean EOF and the VM exits 0.
  let assert Ok(exit_status) = ffi_receive_exit_status(child, 3000)
  exit_status |> should.equal(0)
  ffi_close_child(child)
}

pub fn spawned_child_configured_frame_limit_test() {
  let cmd =
    "erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main"
  let child = ffi_spawn_stdio_child(cmd)
  let over_limit = string.repeat("x", 1025)
  let discover =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("after-over-limit")),
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
  ffi_send_to_child(
    child,
    bit_array.concat([
      bit_array.from_string(over_limit <> "\n"),
      bit_array.from_string(discover <> "\n"),
    ]),
  )

  let assert Ok(response_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(response_string) = bit_array.to_string(response_bytes)
  let assert Ok(response) = json.parse(response_string, decode.dynamic)
  let assert Ok(response_dict) =
    decode.run(response, decode.dict(decode.string, decode.dynamic))
  let assert Ok(error_dyn) = dict.get(response_dict, "error")
  let assert Ok(error_dict) =
    decode.run(error_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(message_dyn) = dict.get(error_dict, "message")
  let assert Ok(message) = decode.run(message_dyn, decode.string)
  message |> should.equal("Frame too large")

  let assert Ok(next_response_bytes) = ffi_receive_from_child(child, 3000)
  let assert Ok(next_response_string) = bit_array.to_string(next_response_bytes)
  let assert Ok(next_response) =
    json.parse(next_response_string, decode.dynamic)
  let assert Ok(next_response_dict) =
    decode.run(next_response, decode.dict(decode.string, decode.dynamic))
  let assert Ok(next_result) = dict.get(next_response_dict, "result")
  let assert Ok(next_result_dict) =
    decode.run(next_result, decode.dict(decode.string, decode.dynamic))
  let assert Ok(versions_dyn) = dict.get(next_result_dict, "supportedVersions")
  let assert Ok(versions) = decode.run(versions_dyn, decode.list(decode.string))
  versions |> should.equal(["2026-07-28"])

  ffi_close_child(child)
}
