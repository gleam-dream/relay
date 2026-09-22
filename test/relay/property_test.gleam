import gleam/bit_array
import gleam/json
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import json/blueprint/codec
import relay/protocol/jsonrpc.{RequestInteger, RequestString}
import relay/server.{
  CloseExchange, EmitRequestAdmitted, ExchangeClosed, InvocationFinished,
  MessageReceived, OutcomeSuccess, StartInvocation, Write,
}
import relay/tool

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_registry() -> tool.Registry(String) {
  let assert Ok(name) = tool.tool_name("echo")
  let assert Ok(t) = case
    tool.definition(name, codec.field("text", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Echoes input"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(text: String) { Ok(text) },
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
        #("arguments", json.object([#("text", json.string(arg))])),
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

// Property 1: Reducer determinism - identical sequence of inputs produces identical effects
pub fn reducer_determinism_property_test() {
  let reg = sample_registry()
  let s_a = server.server(reg)
  let s_b = server.server(reg)

  let ex = server.exchange_id(100)
  let frame = make_call_frame("det-1", "echo", "hello")
  let in1 = MessageReceived(ex, "ctx", frame)

  let #(s_a1, eff_a1) = server.step(s_a, in1)
  let #(s_b1, eff_b1) = server.step(s_b, in1)

  case eff_a1, eff_b1 {
    [EmitRequestAdmitted(_, _), StartInvocation(inv_a)],
      [EmitRequestAdmitted(_, _), StartInvocation(inv_b)]
    -> {
      server.invocation_exchange(inv_a)
      |> should.equal(server.invocation_exchange(inv_b))
      let fin_a = server.perform(inv_a)
      let fin_b = server.perform(inv_b)

      let #(_s_a2, eff_a2) = server.step(s_a1, fin_a)
      let #(_s_b2, eff_b2) = server.step(s_b1, fin_b)

      eff_a2 |> should.equal(eff_b2)
    }
    _, _ -> should.fail()
  }
}

// Property 2: Exactly one terminal response per exchange
pub fn exactly_one_terminal_response_property_test() {
  let reg = sample_registry()
  let s0 = server.server(reg)
  let ex = server.exchange_id(200)

  let frame = make_call_frame("single-term", "echo", "test")
  let #(s1, eff1) = server.step(s0, MessageReceived(ex, "ctx", frame))

  case eff1 {
    [EmitRequestAdmitted(_, _), StartInvocation(inv)] -> {
      let inv_id = server.invocation_id(inv)
      let fin_input =
        InvocationFinished(
          inv_id,
          OutcomeSuccess(
            codec.encode(codec.string(), "done")
            |> fn(r) {
              let assert Ok(v) = r
              v
            },
          ),
        )

      // Step with invocation finished
      let #(s2, eff2) = server.step(s1, fin_input)
      // Expect Write and CloseExchange
      case eff2 {
        [Write(w_ex, _), CloseExchange(c_ex)] -> {
          w_ex |> should.equal(ex)
          c_ex |> should.equal(ex)
        }
        _ -> should.fail()
      }

      // Late second invocation finish on the same invocation ID produces NO effects
      let #(_s3, eff3) = server.step(s2, fin_input)
      eff3 |> should.equal([])

      // Closing exchange again produces NO effects
      let #(_s4, eff4) = server.step(s2, ExchangeClosed(ex))
      eff4 |> should.equal([])
    }
    _ -> should.fail()
  }
}

// Property 3: No invocation before admission
pub fn no_invocation_before_admission_property_test() {
  let reg = sample_registry()
  let s0 = server.server(reg)
  let ex = server.exchange_id(300)

  // 1. Incomplete/corrupted JSON frame
  let bad_frame = bit_array.from_string("{\"jsonrpc\":\"2.0\"")
  let #(_s1, eff1) = server.step(s0, MessageReceived(ex, "ctx", bad_frame))
  // Must NOT start any invocation; must immediately write error response and close exchange
  case eff1 {
    [Write(w_ex, _), CloseExchange(c_ex)] -> {
      w_ex |> should.equal(ex)
      c_ex |> should.equal(ex)
    }
    _ -> should.fail()
  }

  // 2. Discover request (does not start an invocation)
  let disc_frame =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("disc-prop")),
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

  let #(_s2, eff2) = server.step(s0, MessageReceived(ex, "ctx", disc_frame))
  case eff2 {
    [
      EmitRequestAdmitted(_, "server/discover"),
      Write(w_ex, _),
      CloseExchange(c_ex),
    ] -> {
      w_ex |> should.equal(ex)
      c_ex |> should.equal(ex)
    }
    _ -> should.fail()
  }
}

// Property 4: No output after terminal state
pub fn no_output_after_terminal_state_property_test() {
  let reg = sample_registry()
  let s0 = server.server(reg)
  let ex = server.exchange_id(400)

  // Explicitly close exchange before receiving any frame
  let #(s1, eff1) = server.step(s0, ExchangeClosed(ex))
  eff1 |> should.equal([])

  // Attempt to feed message into already-closed exchange
  let frame = make_call_frame("late", "echo", "foo")
  let #(_s2, eff2) = server.step(s1, MessageReceived(ex, "ctx", frame))
  // Must produce NO output effects
  eff2 |> should.equal([])
}

// Property 5: ToolName validated opaque invariant
pub fn tool_name_invariants_property_test() {
  // Valid names
  let assert Ok(n1) = tool.tool_name("valid_name")
  tool.tool_name_to_string(n1) |> should.equal("valid_name")

  let assert Ok(n2) = tool.tool_name("my-tool.v1")
  tool.tool_name_to_string(n2) |> should.equal("my-tool.v1")

  let assert Ok(n3) = tool.tool_name("namespace/tool")
  tool.tool_name_to_string(n3) |> should.equal("namespace/tool")

  // Invalid names: empty, invalid characters, whitespace
  tool.tool_name("") |> should.be_error()
  tool.tool_name("has spaces") |> should.be_error()
  tool.tool_name("tool#bad") |> should.be_error()
  tool.tool_name("tool@bad") |> should.be_error()
}

// Property 6: RequestId string and int representation
pub fn request_id_property_test() {
  let s_id = RequestString("str-123")
  let s_json = jsonrpc.request_id_to_json(s_id)
  json.to_string(s_json) |> should.equal("\"str-123\"")

  let i_id = RequestInteger(456)
  let i_json = jsonrpc.request_id_to_json(i_id)
  json.to_string(i_json) |> should.equal("456")
}
