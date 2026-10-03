import gleam/bit_array
import gleam/json
import gleam/option.{None}
import gleeunit/should
import json/blueprint/codec
import relay/internal/jsonrpc.{RequestInteger, RequestString}
import relay/reducer.{Admitted, Close, ExchangeClosed, Received, Start, Write}
import relay/reducer_support as support
import relay/server.{type Server}
import relay/test_codec
import relay/tool

fn sample_server() -> Server(String) {
  server.new([
    tool.define(
      "echo",
      test_codec.property("text", codec.string()),
      codec.string(),
    )
    |> tool.with_description("Echoes input")
    |> tool.handle(fn(text: String) { Ok(text) }),
  ])
}

fn echo_frame(id: String, arg: String) -> BitArray {
  support.call(id, "echo", [#("text", json.string(arg))])
}

// Property 1: Reducer determinism - identical sequences of inputs produce
// identical effects.
pub fn reducer_determinism_property_test() {
  let srv = sample_server()
  let s_a = reducer.init(srv)
  let s_b = reducer.init(srv)

  let ex = reducer.new_exchange_id()
  let in1 = Received(ex, "ctx", echo_frame("det-1", "hello"), None)

  let #(s_a1, eff_a1) = reducer.step(s_a, in1)
  let #(s_b1, eff_b1) = reducer.step(s_b, in1)

  let assert [Admitted(adm_a, "tools/call"), Start(inv_a)] = eff_a1
  let assert [Admitted(adm_b, "tools/call"), Start(inv_b)] = eff_b1
  adm_a |> should.equal(adm_b)
  reducer.invocation_exchange(inv_a)
  |> should.equal(reducer.invocation_exchange(inv_b))

  let #(_s_a2, eff_a2) =
    reducer.step(s_a1, reducer.perform(inv_a, support.ignore_progress))
  let #(_s_b2, eff_b2) =
    reducer.step(s_b1, reducer.perform(inv_b, support.ignore_progress))
  eff_a2 |> should.equal(eff_b2)
}

// Property 2: Exactly one terminal response per exchange.
pub fn exactly_one_terminal_response_property_test() {
  let s0 = reducer.init(sample_server())
  let #(s1, ex, eff1) = support.receive(s0, "ctx", echo_frame("single", "test"))

  let assert [Admitted(_, _), Start(inv)] = eff1
  let fin_input = reducer.perform(inv, support.ignore_progress)

  let #(s2, eff2) = reducer.step(s1, fin_input)
  let assert [Write(w_ex, _), Close(c_ex)] = eff2
  w_ex |> should.equal(ex)
  c_ex |> should.equal(ex)

  // A second finish of the same invocation produces no effects.
  let #(_s3, eff3) = reducer.step(s2, fin_input)
  eff3 |> should.equal([])

  // Closing the exchange again produces no effects.
  let #(_s4, eff4) = reducer.step(s2, ExchangeClosed(ex))
  eff4 |> should.equal([])

  // Nor do a crash or a timeout reported for the finished invocation.
  let #(_s5, eff5) =
    reducer.step(s2, reducer.Crashed(reducer.invocation_id(inv)))
  eff5 |> should.equal([])
  let #(_s6, eff6) =
    reducer.step(s2, reducer.TimedOut(reducer.invocation_id(inv)))
  eff6 |> should.equal([])
}

// Property 3: No invocation before admission.
pub fn no_invocation_before_admission_property_test() {
  let s0 = reducer.init(sample_server())

  // An incomplete JSON frame is answered and closed without admission.
  let #(_s1, ex1, eff1) =
    support.receive(s0, "ctx", bit_array.from_string("{\"jsonrpc\":\"2.0\""))
  let assert [Write(w_ex, bytes), Close(c_ex)] = eff1
  w_ex |> should.equal(ex1)
  c_ex |> should.equal(ex1)
  support.error_code(bytes) |> should.equal(-32_700)

  // A discover request is admitted but starts no invocation.
  let #(_s2, ex2, eff2) =
    support.receive(
      s0,
      "ctx",
      support.request(json.string("disc-prop"), "server/discover", []),
    )
  let assert [Admitted(a_ex, "server/discover"), Write(w_ex, _), Close(c_ex)] =
    eff2
  a_ex |> should.equal(ex2)
  w_ex |> should.equal(ex2)
  c_ex |> should.equal(ex2)
}

// Property 4: No output after the terminal state.
pub fn no_output_after_terminal_state_property_test() {
  let s0 = reducer.init(sample_server())
  let ex = reducer.new_exchange_id()

  // Close the exchange before any frame arrives.
  let #(s1, eff1) = reducer.step(s0, ExchangeClosed(ex))
  eff1 |> should.equal([])

  // A frame on the closed exchange produces no output.
  let #(_s2, eff2) =
    reducer.step(s1, Received(ex, "ctx", echo_frame("late", "foo"), None))
  eff2 |> should.equal([])
}

// Property 5: Tool names are validated when a definition is built.
pub fn tool_name_invariants_property_test() {
  let input = test_codec.property("text", codec.string())
  let assert Ok(d1) = tool.try_define("valid_name", input, codec.string())
  tool.name(d1) |> should.equal("valid_name")
  let assert Ok(d2) = tool.try_define("my-tool.v1", input, codec.string())
  tool.name(d2) |> should.equal("my-tool.v1")
  let assert Ok(d3) = tool.try_define("namespace/tool", input, codec.string())
  tool.name(d3) |> should.equal("namespace/tool")

  tool.try_define("", input, codec.string())
  |> should.equal(Error(tool.EmptyName))
  tool.try_define("has spaces", input, codec.string())
  |> should.equal(Error(tool.InvalidNameCharacter("has spaces", " ")))
  tool.try_define("tool#bad", input, codec.string())
  |> should.equal(Error(tool.InvalidNameCharacter("tool#bad", "#")))
  tool.try_define("tool@bad", input, codec.string())
  |> should.equal(Error(tool.InvalidNameCharacter("tool@bad", "@")))
}

// Property 6: Request ids keep their string or integer representation.
pub fn request_id_property_test() {
  jsonrpc.request_id_to_json(RequestString("str-123"))
  |> json.to_string
  |> should.equal("\"str-123\"")

  jsonrpc.request_id_to_json(RequestInteger(456))
  |> json.to_string
  |> should.equal("456")
}
