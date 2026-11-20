//// What crosses process boundaries per HTTP request and per tool call, for
//// a server whose tools carry nested combinator codecs.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import json/blueprint/codec.{type Codec}
import relay/client
import relay/http
import relay/reducer
import relay/runtime
import relay/server
import relay/testing
import relay/tool

@external(erlang, "relay_copy_ffi", "flat_bytes")
fn flat_bytes(term: a) -> Int

@external(erlang, "relay_copy_ffi", "crossings")
fn crossings(run: fn() -> a) -> #(a, List(#(String, String, Int)))

// --- a server with nested tool codecs ----------------------------------------

type Currency {
  Brl
  Usd
  Eur
}

type Money {
  Money(amount: Int, currency: Currency)
}

type Line {
  Line(sku: String, quantity: Int, price: Money)
}

type Address {
  Address(street: String, city: String, country: String)
}

type Order {
  Order(
    id: String,
    customer: String,
    address: Address,
    lines: List(Line),
    note: Option(String),
  )
}

type Receipt {
  Receipt(id: String, total: Money, lines: List(Line))
}

fn currency_codec() -> Codec(Currency) {
  codec.string_enum([#("BRL", Brl), #("USD", Usd), #("EUR", Eur)])
}

fn money_codec() -> Codec(Money) {
  use amount <- codec.field("amount", codec.int(), get: fn(m: Money) {
    m.amount
  })
  use currency <- codec.field("currency", currency_codec(), get: fn(m: Money) {
    m.currency
  })
  codec.success(Money(amount, currency))
}

fn line_codec() -> Codec(Line) {
  use sku <- codec.field("sku", codec.string(), get: fn(l: Line) { l.sku })
  use quantity <- codec.field("quantity", codec.int(), get: fn(l: Line) {
    l.quantity
  })
  use price <- codec.field("price", money_codec(), get: fn(l: Line) { l.price })
  codec.success(Line(sku, quantity, price))
}

fn address_codec() -> Codec(Address) {
  use street <- codec.field("street", codec.string(), get: fn(a: Address) {
    a.street
  })
  use city <- codec.field("city", codec.string(), get: fn(a: Address) { a.city })
  use country <- codec.field("country", codec.string(), get: fn(a: Address) {
    a.country
  })
  codec.success(Address(street, city, country))
}

fn order_codec() -> Codec(Order) {
  use id <- codec.field("id", codec.string(), get: fn(o: Order) { o.id })
  use customer <- codec.field("customer", codec.string(), get: fn(o: Order) {
    o.customer
  })
  use address <- codec.field("address", address_codec(), get: fn(o: Order) {
    o.address
  })
  use lines <- codec.field("lines", codec.list(line_codec()), get: fn(o: Order) {
    o.lines
  })
  use note <- codec.optional_field("note", codec.string(), get: fn(o: Order) {
    o.note
  })
  codec.success(Order(id, customer, address, lines, note))
}

fn receipt_codec() -> Codec(Receipt) {
  use id <- codec.field("id", codec.string(), get: fn(r: Receipt) { r.id })
  use total <- codec.field("total", money_codec(), get: fn(r: Receipt) {
    r.total
  })
  use lines <- codec.field(
    "lines",
    codec.list(line_codec()),
    get: fn(r: Receipt) { r.lines },
  )
  codec.success(Receipt(id, total, lines))
}

fn order_tool(name: String) -> tool.Tool(Nil) {
  tool.define(name, order_codec(), receipt_codec())
  |> tool.with_description("Places an order and returns its receipt.")
  |> tool.handle(fn(order: Order) {
    let total =
      list.fold(order.lines, 0, fn(sum, line) {
        sum + line.quantity * line.price.amount
      })
    Ok(Receipt(order.id, Money(total, Brl), order.lines))
  })
}

const tool_count = 12

// --- probes ------------------------------------------------------------------

@external(erlang, "relay_copy_ffi", "heap_bytes")
fn heap_bytes() -> Int

@external(erlang, "relay_copy_ffi", "shared_bytes")
fn shared_bytes() -> Int

@external(erlang, "relay_http_ffi", "request")
fn local_request(
  port: Int,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

@external(erlang, "relay_http_ffi", "send_and_hold")
fn send_and_hold(
  port: Int,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(HeldConnection, String)

@external(erlang, "relay_http_ffi", "read_until")
fn read_until(
  connection: HeldConnection,
  needle: BitArray,
  timeout_ms: Int,
) -> Result(BitArray, String)

@external(erlang, "relay_http_ffi", "abort_connection")
fn abort_connection(connection: HeldConnection) -> BitArray

type HeldConnection

type Probe {
  Probe(heap: Int)
}

fn probe_codec() -> Codec(Probe) {
  use heap <- codec.field("heap", codec.int(), get: fn(p: Probe) { p.heap })
  codec.success(Probe(heap))
}

// A tool with the nested order codec that reports the bytes its invocation
// worker holds after a collection: whatever was copied into that process.
fn probe_definition() -> tool.Definition(Order, Probe) {
  tool.define("probe", order_codec(), probe_codec())
}

fn probe_tool() -> tool.Tool(Nil) {
  probe_definition()
  |> tool.handle(fn(_order: Order) { Ok(Probe(heap_bytes())) })
}

fn probe_server() -> server.Server(Nil) {
  int.range(
    from: 0,
    to: tool_count,
    with: [probe_tool()],
    run: fn(tools, index) {
      [order_tool("order_" <> int.to_string(index)), ..tools]
    },
  )
  |> server.new
}

fn order_arguments() -> json.Json {
  json.object([
    #("id", json.string("o-1")),
    #("customer", json.string("Ada")),
    #(
      "address",
      json.object([
        #("street", json.string("Rua A, 1")),
        #("city", json.string("Recife")),
        #("country", json.string("BR")),
      ]),
    ),
    #(
      "lines",
      json.preprocessed_array([
        json.object([
          #("sku", json.string("sku-1")),
          #("quantity", json.int(2)),
          #(
            "price",
            json.object([
              #("amount", json.int(150)),
              #("currency", json.string("BRL")),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

fn call(name: String) {
  testing.request("tools/call", [
    #("name", json.string(name)),
    #("arguments", order_arguments()),
  ])
}

fn worker_heap(body: String) -> Int {
  let assert Ok(heap) =
    json.parse(body, {
      use heap <- decode.subfield(
        ["result", "structuredContent", "heap"],
        decode.int,
      )
      decode.success(heap)
    })
  heap
}

// The largest term that crossed a process boundary, with its label.
fn largest(seen: List(#(String, String, Int))) -> #(String, Int) {
  list.fold(seen, #("", 0), fn(best, entry) {
    let #(kind, label, bytes) = entry
    case bytes > best.1 {
      True -> #(kind <> " " <> label, bytes)
      False -> best
    }
  })
}

// A tool that answers after its response is due, so a streaming client
// receives it as server-sent events.
fn slow_tool() -> tool.Tool(Nil) {
  tool.define("slow", order_codec(), receipt_codec())
  |> tool.handle(fn(order: Order) {
    process.sleep(150)
    Ok(Receipt(order.id, Money(0, Brl), order.lines))
  })
}

fn envelope(method: String, params: List(#(String, json.Json))) -> BitArray {
  let metadata =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(7)),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", metadata), ..params])),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn stream_headers(method: String) -> List(#(String, String)) {
  [
    #("Accept", "application/json, text/event-stream"),
    #("MCP-Protocol-Version", "2026-07-28"),
    #("Mcp-Method", method),
  ]
}

// One registered tool's own size: a worker may refer to the tool it runs.
fn one_tool_bytes() -> Int {
  flat_bytes(order_tool("order_0"))
}

const slack = 8192

// --- the bounds -----------------------------------------------------------------

/// Every message and spawned closure of one HTTP tools/call and tools/list
/// stays within one tool's size: the endpoint's catalog of 13 nested tools
/// (about 240 kB) never crosses a process boundary.
pub fn http_request_crossings_exclude_the_catalog_test() {
  let srv = probe_server()
  let catalog = flat_bytes(srv)
  let bound = one_tool_bytes() + slack
  assert catalog > 8 * bound
  let assert Ok(handler) = http.handler(http.new(srv))
  let #(response, seen) =
    crossings(fn() { http.handle(handler, call("order_0")) })
  assert response.status == 200
  let #(label, bytes) = largest(seen)
  assert #(label, bytes <= bound) == #(label, True)
  let #(_, seen) =
    crossings(fn() { http.handle(handler, testing.request("tools/list", [])) })
  let #(label, bytes) = largest(seen)
  assert #(label, bytes <= bound) == #(label, True)
  http.stop(handler)
}

/// The streaming paths bound the same way: a tools/call answered as
/// server-sent events, and a `subscriptions/listen` stream up to its
/// acknowledgement, over a real listener.
pub fn http_stream_crossings_exclude_the_catalog_test() {
  let srv = probe_server()
  let assert Ok(srv) = server.register_tool(srv, slow_tool())
  let bound = one_tool_bytes() + slack
  let assert Ok(listener) = http.start(http.new(srv))
  let port = http.port(listener)

  let #(reply, seen) =
    crossings(fn() {
      local_request(
        port,
        "POST",
        [#("Mcp-Name", "slow"), ..stream_headers("tools/call")],
        envelope("tools/call", [
          #("name", json.string("slow")),
          #("arguments", order_arguments()),
        ]),
      )
    })
  let assert Ok(#(200, headers, body)) = reply
  assert list.key_find(headers, "content-type") == Ok("text/event-stream")
  assert string.contains(bit_array_text(body), "\"result\"")
  let #(label, bytes) = largest(seen)
  assert #(label, bytes <= bound) == #(label, True)

  let #(acknowledged, seen) =
    crossings(fn() {
      let assert Ok(connection) =
        send_and_hold(
          port,
          "POST",
          stream_headers("subscriptions/listen"),
          envelope("subscriptions/listen", [
            #(
              "notifications",
              json.object([#("toolsListChanged", json.bool(True))]),
            ),
          ]),
        )
      let acknowledged =
        read_until(
          connection,
          <<"notifications/subscriptions/acknowledged">>,
          2000,
        )
      let _ = abort_connection(connection)
      acknowledged
    })
  let assert Ok(_) = acknowledged
  let #(label, bytes) = largest(seen)
  assert #(label, bytes <= bound) == #(label, True)
  http.stop(listener)
}

fn bit_array_text(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

/// An HTTP invocation worker holds only its own call's data, not a copy of
/// the catalog or of the tool it runs.
pub fn http_invocation_worker_holds_no_copied_catalog_test() {
  let assert Ok(handler) = http.handler(http.new(probe_server()))
  let response = http.handle(handler, call("probe"))
  assert response.status == 200
  let heap = worker_heap(testing.body_text(response))
  assert heap <= slack
  http.stop(handler)
}

/// An in-process connection's runtime keeps its server on its heap: each
/// invocation worker copies its invocation and the one tool it runs, never
/// the runtime state or the rest of the catalog.
pub fn in_process_invocation_copies_one_tool_test() {
  let peer = testing.connect(probe_server(), Nil)
  let bound = one_tool_bytes() + slack
  let #(result, seen) =
    crossings(fn() { client.call(peer, probe_definition(), sample_order()) })
  let assert Ok(client.Succeeded(Probe(heap), _)) = result
  assert heap <= bound
  let #(label, bytes) = largest(seen)
  assert #(label, bytes <= bound) == #(label, True)
  client.close(peer)
}

/// A holding runtime (stdio's) starts each invocation worker with its
/// invocation alone, and the worker copies no tool.
pub fn holding_runtime_invocation_copies_no_tool_test() {
  let self = process.new_subject()
  let assert Ok(rt) =
    runtime.start_holding(probe_server(), runtime.config(), fn(output) {
      process.send(self, output)
      Ok(Nil)
    })
  let bound = one_tool_bytes() + slack
  let #(response, seen) =
    crossings(fn() {
      let assert Ok(Nil) =
        runtime.send_frame(
          rt,
          reducer.new_exchange_id(),
          Nil,
          envelope("tools/call", [
            #("name", json.string("probe")),
            #("arguments", order_arguments()),
          ]),
          None,
        )
      let assert Ok(runtime.OutputWrite(_, bytes)) = process.receive(self, 2000)
      bytes
    })
  assert worker_heap(bit_array_text(response)) <= slack
  let #(label, bytes) = largest(seen)
  assert #(label, bytes <= bound) == #(label, True)
  runtime.stop(rt)
}

fn sample_order() -> Order {
  Order(
    "o-1",
    "Ada",
    Address("Rua A, 1", "Recife", "BR"),
    [Line("sku-1", 2, Money(150, Brl))],
    None,
  )
}

/// Registry churn on a live endpoint serves the current catalog and keeps
/// at most one stored catalog beyond the current one; stopping the endpoint
/// returns the node's shared storage to where it was.
pub fn endpoint_registry_churn_keeps_storage_bounded_test() {
  let base = shared_bytes()
  let assert Ok(handler) = http.handler(http.new(probe_server()))
  let one = shared_bytes() - base
  assert one > 0
  churn(20, fn(index) {
    let name = "extra_" <> int.to_string(index)
    let assert Ok(Nil) = http.register_tool(handler, order_tool(name))
    assert http.handle(handler, call(name)).status == 200
    assert http.unregister_tool(handler, name)
  })
  let listing =
    testing.body_text(http.handle(handler, testing.request("tools/list", [])))
  assert string.contains(listing, "\"order_0\"")
  assert !string.contains(listing, "extra_")
  assert settles(fn() { shared_bytes() - base <= 2 * one }, 50)
  http.stop(handler)
  assert settles(fn() { shared_bytes() - base < one / 2 }, 50)
}

/// A holding runtime (stdio's) keeps storage bounded through registry churn
/// and frees it when it stops.
pub fn runtime_registry_churn_keeps_storage_bounded_test() {
  let base = shared_bytes()
  let assert Ok(rt) =
    runtime.start_holding(probe_server(), runtime.config(), fn(_) { Ok(Nil) })
  let one = shared_bytes() - base
  churn(20, fn(index) {
    let name = "extra_" <> int.to_string(index)
    runtime.register_tool(rt, order_tool(name))
    runtime.unregister_tool(rt, name)
  })
  assert settles(fn() { shared_bytes() - base <= 2 * one }, 50)
  runtime.stop(rt)
  assert settles(fn() { shared_bytes() - base < one / 2 }, 50)
}

fn churn(times: Int, step: fn(Int) -> Nil) -> Nil {
  case times {
    0 -> Nil
    _ -> {
      step(times)
      churn(times - 1, step)
    }
  }
}

fn settles(holds: fn() -> Bool, attempts: Int) -> Bool {
  case holds(), attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      settles(holds, attempts - 1)
    }
  }
}

/// The handler mist copies into every connection holds only the endpoint's
/// address and body limit.
pub fn mist_handler_closure_is_small_test() {
  let assert Ok(handler) = http.handler(http.new(probe_server()))
  assert flat_bytes(http.mist_handler(handler)) <= 1024
  http.stop(handler)
}
