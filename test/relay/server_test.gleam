import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleeunit
import gleeunit/should
import json/blueprint/codec
import relay
import relay/server.{
  type Server, CancelInvocation, CloseExchange, EmitRequestAdmitted,
  MessageReceived, StartInvocation, Write,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_server() -> Server(String) {
  let assert Ok(name) = relay.tool_name("greet")
  let assert Ok(greet_tool) =
    relay.context_tool(
      name,
      relay.tool_metadata("Greets a user"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(ctx: String, user: String) { Ok(ctx <> ": hello " <> user) },
    )
  let assert Ok(reg) = relay.registry([greet_tool])
  server.server(reg)
}

pub fn discovery_step_test() {
  let s = sample_server()
  let ex = server.fresh_exchange()
  let raw =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("disc-1")),
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

  let #(_next_server, effects) =
    server.step(s, MessageReceived(exchange: ex, context: "ctx", bytes: raw))

  case effects {
    [
      EmitRequestAdmitted(_, "server/discover"),
      Write(target_ex, out_bytes),
      CloseExchange(closed_ex),
    ] -> {
      target_ex |> should.equal(ex)
      closed_ex |> should.equal(ex)
      let assert Ok(out_str) = bit_array.to_string(out_bytes)
      let assert Ok(_parsed) = json.parse(out_str, decode.dynamic)
      // Verify valid json
      Nil
    }
    _ -> should.fail()
  }
}

pub fn tools_list_step_test() {
  let s = sample_server()
  let ex = server.fresh_exchange()
  let raw =
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
    |> bit_array.from_string()

  let #(_next_server, effects) =
    server.step(s, MessageReceived(exchange: ex, context: "ctx", bytes: raw))

  case effects {
    [
      EmitRequestAdmitted(_, "tools/list"),
      Write(target_ex, _),
      CloseExchange(closed_ex),
    ] -> {
      target_ex |> should.equal(ex)
      closed_ex |> should.equal(ex)
    }
    _ -> should.fail()
  }
}

pub fn tools_call_lifecycle_test() {
  let s = sample_server()
  let ex = server.fresh_exchange()
  let raw =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("call-1")),
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
          #("arguments", json.object([#("name", json.string("Alice"))])),
        ]),
      ),
    ])
    |> json.to_string()
    |> bit_array.from_string()

  let #(s1, effects1) =
    server.step(
      s,
      MessageReceived(exchange: ex, context: "server-ctx", bytes: raw),
    )

  case effects1 {
    [EmitRequestAdmitted(_, "tools/call"), StartInvocation(inv)] -> {
      server.invocation_exchange(inv) |> should.equal(ex)
      let _inv_id = server.invocation_id(inv)

      // Perform the invocation
      let finish_input = server.perform(inv)

      // Step with finished invocation
      let #(s2, effects2) = server.step(s1, finish_input)
      case effects2 {
        [Write(target_ex, out_bytes), CloseExchange(closed_ex)] -> {
          target_ex |> should.equal(ex)
          closed_ex |> should.equal(ex)
          let assert Ok(out_str) = bit_array.to_string(out_bytes)
          let assert Ok(_parsed) = json.parse(out_str, decode.dynamic)
          Nil
        }
        _ -> should.fail()
      }

      // Late replay of invocation finished produces NO effects
      let #(_s3, effects3) = server.step(s2, finish_input)
      effects3 |> should.equal([])
    }
    _ -> should.fail()
  }
}

pub fn client_cancellation_test() {
  let s = sample_server()
  let ex = server.fresh_exchange()
  let raw_call =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("cancel-me")),
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
    |> bit_array.from_string()

  let #(s1, effects1) =
    server.step(
      s,
      MessageReceived(exchange: ex, context: "ctx", bytes: raw_call),
    )

  let assert [EmitRequestAdmitted(_, "tools/call"), StartInvocation(inv)] =
    effects1
  let inv_id = server.invocation_id(inv)

  // Now send cancellation notification
  let cancel_ex = server.fresh_exchange()
  let raw_cancel =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("notifications/cancelled")),
      #("params", json.object([#("requestId", json.string("cancel-me"))])),
    ])
    |> json.to_string()
    |> bit_array.from_string()

  let #(s2, effects2) =
    server.step(
      s1,
      MessageReceived(exchange: cancel_ex, context: "ctx", bytes: raw_cancel),
    )

  case effects2 {
    [CancelInvocation(cancelled_id), CloseExchange(_), CloseExchange(_)] -> {
      cancelled_id |> should.equal(inv_id)
    }
    _ -> should.fail()
  }

  // Late completion after cancel produces NO effects
  let late_finish = server.perform(inv)
  let #(_s3, effects3) = server.step(s2, late_finish)
  effects3 |> should.equal([])
}
