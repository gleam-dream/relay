import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleeunit
import gleeunit/should
import relay/transport/stdio.{Frame, FrameOversized, InvalidTrailingBytes}

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "relay_ffi", "spawn_stdio_child")
fn ffi_spawn_stdio_child(cmd: String) -> dynamic.Dynamic

@external(erlang, "relay_ffi", "send_to_child")
fn ffi_send_to_child(port: dynamic.Dynamic, bytes: BitArray) -> Nil

@external(erlang, "relay_ffi", "receive_from_child")
fn ffi_receive_from_child(
  port: dynamic.Dynamic,
  timeout_ms: Int,
) -> Result(BitArray, Nil)

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
