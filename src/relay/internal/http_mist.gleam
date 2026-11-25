//// The mist side of the HTTP endpoint: reads a bounded body, watches the
//// socket while a buffered reply is computed, and streams server-sent
//// events with chunked encoding and keepalive comments.
////
//// It depends on mist, gleam_http and gleam_erlang only, never on Relay's
//// types: `relay/http` passes closures. It can move to a separate package
//// unchanged.

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option, None, Some}
import mist

/// What the endpoint answers.
pub type Reply {
  Buffered(Response(BytesTree))
  /// A server-sent event stream: `head` carries the status and headers;
  /// `next(wait_ms)` returns the next event, or `Idle` when nothing arrived
  /// within the wait; `close` tells the endpoint the client went away.
  Streamed(
    head: Response(Nil),
    next: fn(Int) -> Event,
    close: fn() -> Nil,
    keepalive_ms: Int,
    write_budget: fn() -> Result(Int, Nil),
    written: fn(Event) -> Nil,
    attached: fn(process.Pid) -> Bool,
    lifetime: Lifetime,
  )
}

/// How a streamed response ends. The writer owns the socket and closes it
/// when the stream ends, so no client may reuse the connection afterwards.
pub type Lifetime {
  /// A response that completes: the writer sends the final chunk and then
  /// closes the connection, and the head says `connection: close`.
  Finite
  /// A subscription, open until its owner ends it. The head does not say
  /// `connection: close`: a client that reads it may end the open response
  /// on its own graceful-close timer (gun's `closing_timeout` ends it after
  /// 15 s). When the server ends the stream, the writer closes the socket
  /// before the final chunk, so the response never completes and no client
  /// reuses the connection.
  Open
}

pub type Event {
  /// One JSON-RPC message, to send as one `data:` event.
  Data(BitArray)
  Idle
  Ended
}

/// The callbacks of one endpoint.
pub type Endpoint {
  Endpoint(
    max_body_bytes: Int,
    serve: fn(Request(BitArray), process.Selector(Nil)) -> Reply,
    body_too_large: fn() -> Response(BytesTree),
    malformed_body: fn() -> Response(BytesTree),
  )
}

/// A mist handler for the endpoint.
pub fn handler(
  endpoint: Endpoint,
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  fn(request) { handle(endpoint, request) }
}

fn handle(
  endpoint: Endpoint,
  request: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case read_bounded_body(request, endpoint.max_body_bytes) {
    Error(TooLarge) ->
      endpoint.body_too_large()
      |> response.set_header("connection", "close")
      |> response.map(mist.Bytes)
    Error(Malformed) -> endpoint.malformed_body() |> response.map(mist.Bytes)
    Ok(body) -> {
      let closed = client_closed(request.body)
      case endpoint.serve(request.set_body(request, body), closed) {
        Buffered(reply) -> response.map(reply, mist.Bytes)
        Streamed(
          head,
          next,
          close,
          keepalive_ms,
          write_budget,
          written,
          attached,
          lifetime,
        ) -> {
          case write_budget() {
            Error(Nil) -> {
              close()
              response.new(504)
              |> response.set_header("connection", "close")
              |> response.set_body(mist.Bytes(bytes_tree.new()))
            }
            Ok(timeout) -> {
              let _ = set_send_timeout(request.body, timeout)
              stream(
                request,
                head,
                next,
                close,
                keepalive_ms,
                write_budget,
                written,
                attached,
                lifetime,
              )
            }
          }
        }
      }
    }
  }
}

type BodyError {
  TooLarge
  Malformed
}

fn read_bounded_body(
  request: Request(mist.Connection),
  limit: Int,
) -> Result(BitArray, BodyError) {
  case mist.stream(request) {
    Error(_) -> Error(Malformed)
    Ok(consume) -> read_chunks(consume, limit, <<>>)
  }
}

fn read_chunks(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  limit: Int,
  body: BitArray,
) -> Result(BitArray, BodyError) {
  let remaining = limit - bit_array.byte_size(body)
  case consume(int.min(16_384, remaining + 1)) {
    Error(_) -> Error(Malformed)
    Ok(mist.Done) -> Ok(body)
    Ok(mist.Chunk(chunk, next)) ->
      case bit_array.byte_size(chunk) > remaining {
        True -> Error(TooLarge)
        False -> read_chunks(next, limit, bit_array.append(body, chunk))
      }
  }
}

// A buffered reply writes nothing until it is ready, so the request process
// arms one closure message on the socket and selects on it.
fn client_closed(connection: mist.Connection) -> process.Selector(Nil) {
  case watch_client_close(connection) {
    Error(Nil) -> process.new_selector()
    Ok(Nil) ->
      process.new_selector()
      |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Nil })
      |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Nil })
      |> process.select_record(atom.create("tcp_error"), 2, fn(_) { Nil })
      |> process.select_record(atom.create("ssl_error"), 2, fn(_) { Nil })
  }
}

type Pull {
  Pull
}

fn stream(
  request: Request(mist.Connection),
  head: Response(Nil),
  next: fn(Int) -> Event,
  close: fn() -> Nil,
  keepalive_ms: Int,
  write_budget: fn() -> Result(Int, Nil),
  written: fn(Event) -> Nil,
  attached: fn(process.Pid) -> Bool,
  lifetime: Lifetime,
) -> Response(mist.ResponseData) {
  let head = case lifetime {
    Finite -> response.set_header(head, "connection", "close")
    Open -> head
  }
  mist.chunked(
    request: request,
    response: head,
    init: fn(subject) {
      // Mist starts this process through its factory. Refuse initialization
      // unless the request owner has registered its lifetime before first pull.
      let assert True = attached(process.self())
        as "Relay request ended before stream initialization"
      process.send(subject, Pull)
      subject
    },
    loop: fn(subject, _pull, connection) {
      let pulled = next(keepalive_ms)
      let bytes = case pulled {
        Data(bytes) -> Some(event(bytes))
        Idle -> Some(<<": keepalive\n\n">>)
        Ended -> None
      }
      case bytes {
        None ->
          case lifetime, write_budget() {
            Open, _ -> {
              close_connection(connection)
              mist.chunk_stop()
            }
            Finite, Error(Nil) ->
              mist.chunk_stop_abnormal("Relay request ended")
            Finite, Ok(timeout) -> {
              let _ = set_send_timeout(connection, timeout)
              mist.chunk_stop()
            }
          }
        Some(bytes) -> {
          case write_budget() {
            Error(Nil) -> {
              close()
              mist.chunk_stop_abnormal("Relay request ended")
            }
            Ok(timeout) -> {
              let _ = set_send_timeout(connection, timeout)
              case mist.send_chunk(connection, bytes) {
                Ok(Nil) -> {
                  written(pulled)
                  process.send(subject, Pull)
                  mist.chunk_continue(subject)
                }
                Error(_) -> {
                  close()
                  mist.chunk_stop()
                }
              }
            }
          }
        }
      }
    },
  )
}

fn event(bytes: BitArray) -> BitArray {
  let data = case bit_array.byte_size(bytes) {
    0 -> bytes
    size ->
      case bit_array.slice(bytes, size - 1, 1) {
        Ok(<<"\n">>) ->
          case bit_array.slice(bytes, 0, size - 1) {
            Ok(trimmed) -> trimmed
            Error(Nil) -> bytes
          }
        _ -> bytes
      }
  }
  bit_array.concat([<<"data: ">>, data, <<"\n\n">>])
}

/// Starts mist on `host` and `port` with optional TLS files. Returns the
/// listener supervisor and the bound port.
pub fn start(
  handler: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
  host: String,
  port: Int,
  tls: Option(#(String, String)),
) -> Result(#(process.Pid, Int), Nil) {
  let reported = process.new_subject()
  let builder =
    mist.new(handler)
    |> mist.port(port)
    |> mist.bind(host)
    |> mist.after_start(fn(bound, _scheme, _interface) {
      process.send(reported, bound)
    })
  let builder = case tls {
    None -> builder
    Some(#(certfile, keyfile)) -> mist.with_tls(builder, certfile, keyfile)
  }
  case mist.start(builder) {
    Error(_) -> Error(Nil)
    Ok(started) ->
      case process.receive(reported, 5000) {
        Ok(bound) -> Ok(#(started.pid, bound))
        Error(Nil) -> {
          stop(started.pid)
          Error(Nil)
        }
      }
  }
}

/// Stops a listener started by `start`.
pub fn stop(listener: process.Pid) -> Nil {
  // This shutdown is requested by the owner, not a listener failure.
  process.unlink(listener)
  stop_supervisor(listener)
}

@external(erlang, "relay_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

// mist offers no public way to set socket options, arm a closure message or
// close the socket; these read its connection record and fail safely when the
// record shape changes.
@external(erlang, "relay_ffi", "close_connection")
fn close_connection(connection: mist.Connection) -> Nil

@external(erlang, "relay_ffi", "watch_client_close")
fn watch_client_close(connection: mist.Connection) -> Result(Nil, Nil)

@external(erlang, "relay_ffi", "set_send_timeout")
fn set_send_timeout(
  connection: mist.Connection,
  timeout_ms: Int,
) -> Result(Nil, Nil)
