//// What crosses process boundaries per HTTP request and per tool call, for
//// a server whose tools carry nested combinator codecs.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import json/blueprint/codec.{type Codec}
import relay/client
import relay/http
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

@external(erlang, "relay_copy_ffi", "held_count")
fn held_count(marker: String) -> Int

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

/// A connection runtime (stdio, in-process client) starts each invocation
/// worker with its invocation alone: no runtime state, no catalog copy.
pub fn runtime_invocation_crossings_exclude_the_catalog_test() {
  let peer = testing.connect(probe_server(), Nil)
  let bound = one_tool_bytes() + slack
  let order =
    Order(
      "o-1",
      "Ada",
      Address("Rua A, 1", "Recife", "BR"),
      [Line("sku-1", 2, Money(150, Brl))],
      None,
    )
  let #(result, seen) =
    crossings(fn() { client.call(peer, probe_definition(), order) })
  let assert Ok(client.Succeeded(Probe(heap), _)) = result
  assert heap <= slack
  let #(label, bytes) = largest(seen)
  assert #(label, bytes <= bound) == #(label, True)
}

/// Registry changes hold one new snapshot and release the old ones; stopping
/// the endpoint releases the last.
pub fn registry_changes_release_old_snapshots_test() {
  let marker = "snapshot_marker_tool"
  let assert Ok(handler) =
    http.handler(http.new(server.new([order_tool(marker)])))
  assert held_count(marker) == 1
  let assert Ok(Nil) = http.register_tool(handler, order_tool("extra_1"))
  let assert Ok(Nil) = http.register_tool(handler, order_tool("extra_2"))
  assert http.unregister_tool(handler, "extra_1")
  assert released(marker, 1, 50)
  let response = http.handle(handler, call("extra_2"))
  assert response.status == 200
  http.stop(handler)
  assert released(marker, 0, 50)
}

fn released(marker: String, count: Int, attempts: Int) -> Bool {
  case held_count(marker) == count, attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      released(marker, count, attempts - 1)
    }
  }
}

/// A connection runtime holds its own catalog for its lifetime, holds it
/// again after a registry change, and frees it when it stops.
pub fn runtime_registry_changes_release_old_snapshots_test() {
  let marker = "runtime_marker_tool"
  let assert Ok(rt) =
    runtime.start(server.new([order_tool(marker)]), runtime.config(), fn(_) {
      Ok(Nil)
    })
  assert released(marker, 1, 50)
  runtime.register_tool(rt, order_tool("extra_1"))
  runtime.unregister_tool(rt, "extra_1")
  runtime.register_tool(rt, order_tool(marker))
  assert released(marker, 1, 50)
  runtime.stop(rt)
  assert released(marker, 0, 50)
}

/// The handler mist copies into every connection holds only the endpoint's
/// address and body limit.
pub fn mist_handler_closure_is_small_test() {
  let assert Ok(handler) = http.handler(http.new(probe_server()))
  assert flat_bytes(http.mist_handler(handler)) <= 1024
  http.stop(handler)
}
