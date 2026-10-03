import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleam/time/duration
import relay/internal/stdio_frames.{Frame, FrameOversized, InvalidTrailingBytes}
import relay/runtime
import relay/server
import relay/stdio

const runner = "erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main"

@external(erlang, "relay_ffi", "spawn_stdio_child")
fn spawn_child(cmd: String) -> Dynamic

@external(erlang, "relay_ffi", "spawn_stdio_child_closed_stdout")
fn spawn_child_closed_stdout(cmd: String) -> Dynamic

@external(erlang, "relay_ffi", "send_to_child")
fn send_to_child(port: Dynamic, bytes: BitArray) -> Nil

@external(erlang, "relay_ffi", "receive_from_child")
fn receive_from_child(port: Dynamic, timeout_ms: Int) -> Result(BitArray, Nil)

@external(erlang, "relay_ffi", "receive_exit_status")
fn receive_exit_status(port: Dynamic, timeout_ms: Int) -> Result(Int, Nil)

@external(erlang, "relay_ffi", "close_child")
fn close_child(port: Dynamic) -> Nil

// --- helpers -----------------------------------------------------------------

fn request_line(
  id: String,
  method: String,
  params: List(#(String, json.Json)),
) -> BitArray {
  let meta =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", meta), ..params])),
  ])
  |> json.to_string
  |> string.append("\n")
  |> bit_array.from_string
}

// Reads from the child until `count` complete lines arrived.
fn read_lines(child: Dynamic, count: Int) -> List(Dynamic) {
  collect_lines(child, count, "")
}

fn collect_lines(child: Dynamic, count: Int, buffer: String) -> List(Dynamic) {
  let lines =
    string.split(buffer, "\n")
    |> list.reverse
    |> list.drop(1)
    |> list.reverse
  case list.length(lines) >= count {
    True ->
      list.take(lines, count)
      |> list.map(fn(line) {
        let assert Ok(message) = json.parse(line, decode.dynamic)
        message
      })
    False -> {
      let assert Ok(chunk) = receive_from_child(child, 5000)
      let assert Ok(text) = bit_array.to_string(chunk)
      collect_lines(child, count, buffer <> text)
    }
  }
}

fn read_one(child: Dynamic) -> Dynamic {
  let assert [message] = read_lines(child, 1)
  message
}

fn at(message: Dynamic, path: List(String), decoder: decode.Decoder(a)) -> a {
  let assert Ok(found) = decode.run(message, decode.at(path, decoder))
  found
}

// --- configuration -----------------------------------------------------------

pub fn stdio_rejects_invalid_settings_before_io_test() {
  let service = server.new([])
  let assert Error(stdio.InvalidChunkSize(0)) =
    stdio.serve_with(service, Nil, stdio.config() |> stdio.with_chunk_size(0))

  let bad_runtime =
    runtime.config()
    |> runtime.with_invocation_timeout(duration.milliseconds(0))
  let assert Error(stdio.InvalidRuntimeConfig(runtime.InvocationTimeout)) =
    stdio.serve_with(
      service,
      Nil,
      stdio.config() |> stdio.with_runtime(bad_runtime),
    )

  let bad_frames = runtime.config() |> runtime.with_max_frame_bytes(0)
  let assert Error(stdio.InvalidRuntimeConfig(runtime.MaxFrameBytes)) =
    stdio.serve_with(
      service,
      Nil,
      stdio.config() |> stdio.with_runtime(bad_frames),
    )

  let assert True = stdio.describe_error(stdio.InvalidChunkSize(0)) != ""
  let assert "standard input ended in the middle of a frame" =
    stdio.describe_error(stdio.InvalidTrailingData(<<"x">>))
}

// --- framer ------------------------------------------------------------------

pub fn framer_single_frame_test() {
  let #(framer, frames) =
    stdio_frames.new_framer(1024)
    |> stdio_frames.feed_framer(<<"{\"jsonrpc\":\"2.0\"}\n">>)
  let assert [Frame(<<"{\"jsonrpc\":\"2.0\"}">>)] = frames
  let assert [] = stdio_frames.finish_framer(framer)
}

pub fn framer_crlf_frame_test() {
  let #(framer, frames) =
    stdio_frames.new_framer(1024)
    |> stdio_frames.feed_framer(<<"{\"jsonrpc\":\"2.0\"}\r\n">>)
  let assert [Frame(<<"{\"jsonrpc\":\"2.0\"}">>)] = frames
  let assert [] = stdio_frames.finish_framer(framer)
}

pub fn framer_multiple_frames_in_one_chunk_test() {
  let #(_, frames) =
    stdio_frames.new_framer(1024)
    |> stdio_frames.feed_framer(<<"line1\nline2\nline3\n">>)
  let assert [Frame(<<"line1">>), Frame(<<"line2">>), Frame(<<"line3">>)] =
    frames
}

pub fn framer_partial_read_test() {
  let #(first, frames) =
    stdio_frames.new_framer(1024)
    |> stdio_frames.feed_framer(<<"{\"jsonrpc\":">>)
  let assert [] = frames
  let #(second, frames) = stdio_frames.feed_framer(first, <<"\"2.0\"}\n">>)
  let assert [Frame(<<"{\"jsonrpc\":\"2.0\"}">>)] = frames
  let assert [] = stdio_frames.finish_framer(second)
}

pub fn framer_utf8_split_across_chunks_test() {
  // "€" is three bytes in UTF-8: 226, 130, 172.
  let #(first, frames) =
    stdio_frames.new_framer(1024)
    |> stdio_frames.feed_framer(<<"{\"currency\":\"":utf8, 226, 130>>)
  let assert [] = frames
  let #(_, frames) = stdio_frames.feed_framer(first, <<172, "\"}\n":utf8>>)
  let assert [Frame(line)] = frames
  let assert Ok("{\"currency\":\"€\"}") = bit_array.to_string(line)
}

pub fn framer_oversized_frame_test() {
  let #(_, frames) =
    stdio_frames.new_framer(10)
    |> stdio_frames.feed_framer(<<"this is definitely longer than 10 bytes\n">>)
  let assert [FrameOversized(39, 10)] = frames
}

pub fn framer_discards_the_remainder_of_an_oversized_frame_test() {
  let #(first, frames) =
    stdio_frames.new_framer(3)
    |> stdio_frames.feed_framer(<<"abcd">>)
  let assert [FrameOversized(4, 3)] = frames
  let #(second, frames) =
    stdio_frames.feed_framer(first, <<"discard this\nok\n">>)
  let assert [Frame(<<"ok">>)] = frames
  let assert [] = stdio_frames.finish_framer(second)
}

pub fn framer_incomplete_eof_test() {
  let #(framer, frames) =
    stdio_frames.new_framer(1024)
    |> stdio_frames.feed_framer(<<"incomplete frame without newline">>)
  let assert [] = frames
  let assert [InvalidTrailingBytes(<<"incomplete frame without newline">>)] =
    stdio_frames.finish_framer(framer)
}

pub fn writer_failure_is_returned_to_the_caller_test() {
  let assert Ok(writer) =
    stdio_frames.start_writer(fn(_bytes) { Error("closed pipe") })
  let assert Error("closed pipe") =
    stdio_frames.write_bytes(writer, <<"response\n">>)
  stdio_frames.stop_writer(writer)
}

// --- a spawned child over OS pipes -------------------------------------------

pub fn spawned_child_stdio_server_test() {
  let child = spawn_child(runner)

  send_to_child(child, request_line("disc-child-1", "server/discover", []))
  let discovery = read_one(child)
  let assert "disc-child-1" = at(discovery, ["id"], decode.string)
  let assert "relay" =
    at(
      discovery,
      ["result", "_meta", "io.modelcontextprotocol/serverInfo", "name"],
      decode.string,
    )

  send_to_child(child, request_line("list-1", "tools/list", []))
  let names =
    at(
      read_one(child),
      ["result", "tools"],
      decode.list(decode.at(["name"], decode.string)),
    )
  let assert True = list.contains(names, "greet")
  let assert True = list.contains(names, "fail_tool")

  send_to_child(
    child,
    request_line("call-greet", "tools/call", [
      #("name", json.string("greet")),
      #("arguments", json.object([#("name", json.string("Bob"))])),
    ]),
  )
  let assert "child-server: hello Bob" =
    at(read_one(child), ["result", "structuredContent"], decode.string)

  send_to_child(
    child,
    request_line("call-fail", "tools/call", [
      #("name", json.string("fail_tool")),
      #("arguments", json.object([#("msg", json.string("boom"))])),
    ]),
  )
  let failure = read_one(child)
  let assert True = at(failure, ["result", "isError"], decode.bool)
  let assert ["application error: boom"] =
    at(
      failure,
      ["result", "content"],
      decode.list(decode.at(["text"], decode.string)),
    )

  close_child(child)
}

pub fn asynchronous_broken_stdout_stops_with_idle_stdin_test() {
  let child = spawn_child_closed_stdout(runner)
  send_to_child(
    child,
    request_line("slow-pipe", "tools/call", [
      #("name", json.string("slow")),
      #("arguments", json.object([#("ms", json.int(150))])),
    ]),
  )
  // The input pipe stays open while the delayed handler writes its reply.
  expect_exit(child, 1)
}

pub fn oversized_frame_refusal_on_broken_stdout_stops_the_server_test() {
  let child = spawn_child_closed_stdout(runner)
  send_to_child(child, bit_array.from_string(string.repeat("x", 1100) <> "\n"))
  expect_exit(child, 1)
}

fn expect_exit(child: Dynamic, status: Int) -> Nil {
  case receive_exit_status(child, 3000) {
    Ok(found) -> {
      close_child(child)
      let assert True = found == status
      Nil
    }
    Error(_) -> {
      // Release the child's input so a failed run leaves no process behind.
      send_to_child(child, <<"close\n">>)
      let _ = receive_exit_status(child, 2000)
      close_child(child)
      panic as "the stdio server did not stop"
    }
  }
}

pub fn spawned_child_partial_utf8_across_chunks_test() {
  let child = spawn_child(runner)
  let line =
    request_line("split-utf8", "tools/call", [
      #("name", json.string("greet")),
      #("arguments", json.object([#("name", json.string("€"))])),
    ])
  // Split inside the three bytes of "€".
  let assert Ok(text) = bit_array.to_string(line)
  let assert Ok(#(before, after)) = string.split_once(text, "€")
  send_to_child(child, <<before:utf8, 226, 130>>)
  send_to_child(child, <<172, after:utf8>>)
  let assert "child-server: hello €" =
    at(read_one(child), ["result", "structuredContent"], decode.string)
  close_child(child)
}

pub fn spawned_child_multi_frame_chunk_test() {
  let child = spawn_child(runner)
  send_to_child(
    child,
    bit_array.append(
      request_line("multi-1", "server/discover", []),
      request_line("multi-2", "tools/list", []),
    ),
  )
  let assert [first, second] = read_lines(child, 2)
  let ids = [
    at(first, ["id"], decode.string),
    at(second, ["id"], decode.string),
  ]
  let assert True =
    list.contains(ids, "multi-1") && list.contains(ids, "multi-2")
  close_child(child)
}

pub fn spawned_child_eof_clean_shutdown_test() {
  // A real /dev/null stdin reaches the server as a clean EOF: exit 0.
  let child = spawn_child(runner <> " </dev/null")
  let assert Ok(0) = receive_exit_status(child, 5000)
  close_child(child)
}

pub fn spawned_child_trailing_bytes_at_eof_test() {
  // Standard input ends in the middle of a frame: InvalidTrailingData.
  let child = spawn_child("printf 'partial frame' | " <> runner)
  let assert Ok(3) = receive_exit_status(child, 5000)
  close_child(child)
}

pub fn spawned_child_configured_frame_limit_test() {
  let child = spawn_child(runner)
  send_to_child(
    child,
    bit_array.append(
      bit_array.from_string(string.repeat("x", 1025) <> "\n"),
      request_line("after-over-limit", "server/discover", []),
    ),
  )
  let assert [refusal, discovery] = read_lines(child, 2)
  let assert -32_600 = at(refusal, ["error", "code"], decode.int)
  let assert "Frame too large" =
    at(refusal, ["error", "message"], decode.string)
  let assert ["2026-07-28"] =
    at(discovery, ["result", "supportedVersions"], decode.list(decode.string))
  close_child(child)
}

pub fn spawned_child_too_deep_frame_is_answered_test() {
  let child = spawn_child(runner)
  // 20 nested arrays: deeper than the runner's limit of 16, well under its
  // 1,024-byte frame limit.
  let deep = string.repeat("[", 20) <> string.repeat("]", 20)
  let frame =
    "{\"jsonrpc\":\"2.0\",\"id\":\"deep\",\"method\":\"tools/call\",\"params\":{\"name\":\"greet\",\"arguments\":{\"name\":"
    <> deep
    <> "}}}\n"
  send_to_child(
    child,
    bit_array.append(
      bit_array.from_string(frame),
      request_line("after-deep", "server/discover", []),
    ),
  )
  let assert [refusal, discovery] = read_lines(child, 2)
  let assert -32_600 = at(refusal, ["error", "code"], decode.int)
  let assert "JSON nesting exceeds the configured depth" =
    at(refusal, ["error", "message"], decode.string)
  let assert "after-deep" = at(discovery, ["id"], decode.string)
  close_child(child)
}
