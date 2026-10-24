import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleeunit/should
import json/blueprint/codec
import relay/reducer.{Admitted, Cancel, Close, Start, Write}
import relay/reducer_support as support
import relay/server.{type Server}
import relay/test_codec
import relay/tool

fn greet_tool(name: String) -> tool.Tool(String) {
  tool.define(name, test_codec.property("name", codec.string()), codec.string())
  |> tool.with_description("Greets a user")
  |> tool.handle_call(fn(call, user) {
    Ok(tool.complete(tool.context(call) <> ": hello " <> user))
  })
}

fn sample_server() -> Server(String) {
  server.new([greet_tool("greet")])
}

pub fn discovery_step_test() {
  let state = reducer.init(sample_server())
  let #(_state, ex, effects) =
    support.receive(
      state,
      "ctx",
      support.request(json.string("disc-1"), "server/discover", []),
    )

  let assert [
    Admitted(admitted_ex, "server/discover"),
    Write(target_ex, out_bytes),
    Close(closed_ex),
  ] = effects
  admitted_ex |> should.equal(ex)
  target_ex |> should.equal(ex)
  closed_ex |> should.equal(ex)
  support.at(out_bytes, ["id"], decode.string) |> should.equal("disc-1")
  support.at(
    out_bytes,
    ["result", "supportedVersions"],
    decode.list(decode.string),
  )
  |> should.equal(["2026-07-28"])
}

pub fn tools_list_step_test() {
  let state = reducer.init(sample_server())
  let #(_state, ex, effects) =
    support.receive(
      state,
      "ctx",
      support.request(json.int(10), "tools/list", []),
    )

  let assert [
    Admitted(_, "tools/list"),
    Write(target_ex, out_bytes),
    Close(closed_ex),
  ] = effects
  target_ex |> should.equal(ex)
  closed_ex |> should.equal(ex)
  support.at(
    out_bytes,
    ["result", "tools"],
    decode.list(decode.at(["description"], decode.string)),
  )
  |> should.equal(["Greets a user"])
}

pub fn tools_call_lifecycle_test() {
  let state = reducer.init(sample_server())
  let #(s1, ex, effects1) =
    support.receive(
      state,
      "server-ctx",
      support.call("call-1", "greet", [#("name", json.string("Alice"))]),
    )

  let assert [Admitted(_, "tools/call"), Start(inv)] = effects1
  reducer.invocation_exchange(inv) |> should.equal(ex)
  reducer.invocation_method(inv) |> should.equal("tools/call")
  reducer.invocation_tool(inv) |> should.equal(option.Some("greet"))
  reducer.invocation_context(inv) |> should.equal("server-ctx")

  // Perform the invocation and feed its result back.
  let finish_input = reducer.perform(inv, support.ignore_progress)
  let #(s2, effects2) = reducer.step(s1, finish_input)
  let assert [Write(target_ex, out_bytes), Close(closed_ex)] = effects2
  target_ex |> should.equal(ex)
  closed_ex |> should.equal(ex)
  support.at(out_bytes, ["result", "structuredContent"], decode.string)
  |> should.equal("server-ctx: hello Alice")

  // A late replay of the finished invocation produces no effects.
  let #(_s3, effects3) = reducer.step(s2, finish_input)
  effects3 |> should.equal([])
}

pub fn client_cancellation_test() {
  let state = reducer.init(sample_server())
  let #(s1, call_ex, effects1) =
    support.receive(
      state,
      "ctx",
      support.call("cancel-me", "greet", [#("name", json.string("Bob"))]),
    )
  let assert [Admitted(_, "tools/call"), Start(inv)] = effects1
  let inv_id = reducer.invocation_id(inv)

  let #(s2, cancel_ex, effects2) =
    support.receive(s1, "ctx", support.cancel("cancel-me"))
  effects2
  |> should.equal([Cancel(inv_id), Close(call_ex), Close(cancel_ex)])

  // A late completion after the cancellation produces no effects.
  let late_finish = reducer.perform(inv, support.ignore_progress)
  let #(_s3, effects3) = reducer.step(s2, late_finish)
  effects3 |> should.equal([])
}

// --- tool access -------------------------------------------------------------

// Guests see `public` and `readonly` and may call only `public`; `hidden` is
// invisible to them. Admins see and call everything.
fn guarded_server() -> Server(String) {
  server.new([
    greet_tool("public"),
    greet_tool("hidden"),
    greet_tool("readonly"),
  ])
  |> server.with_tool_access(
    visible: fn(context, declaration: tool.Declaration) {
      context == "admin" || declaration.name != "hidden"
    },
    callable: fn(context, declaration: tool.Declaration) {
      context == "admin" || declaration.name != "readonly"
    },
  )
}

fn listed_names(context: String) -> List(String) {
  let #(_state, _ex, effects) =
    support.receive(
      reducer.init(guarded_server()),
      context,
      support.request(json.int(1), "tools/list", []),
    )
  let assert [Admitted(_, "tools/list"), Write(_, bytes), Close(_)] = effects
  support.at(
    bytes,
    ["result", "tools"],
    decode.list(decode.at(["name"], decode.string)),
  )
}

pub fn tool_access_hides_invisible_tools_from_list_test() {
  listed_names("guest") |> should.equal(["public", "readonly"])
  listed_names("admin") |> should.equal(["public", "hidden", "readonly"])
  // The description itself still holds every tool.
  server.tools(guarded_server())
  |> list.map(fn(declaration) { declaration.name })
  |> should.equal(["public", "hidden", "readonly"])
}

fn guest_call(
  name: String,
) -> #(reducer.ExchangeId, List(reducer.Effect(String))) {
  let #(_state, ex, effects) =
    support.receive(
      reducer.init(guarded_server()),
      "guest",
      support.call("same", name, [#("name", json.string("Eve"))]),
    )
  #(ex, effects)
}

pub fn tool_access_hidden_denied_and_unknown_calls_answer_alike_test() {
  let answers =
    list.map(["hidden", "readonly", "missing"], fn(name) {
      let #(ex, effects) = guest_call(name)
      // Answered immediately: no admission, no invocation.
      let assert [Write(written, bytes), Close(closed)] = effects
      written |> should.equal(ex)
      closed |> should.equal(ex)
      support.error_code(bytes) |> should.equal(-32_602)
      support.text(bytes)
    })
  let assert [hidden, denied, unknown] = answers
  hidden |> should.equal(denied)
  denied |> should.equal(unknown)

  // A visible and callable tool starts an invocation.
  let #(_ex, effects) = guest_call("public")
  let assert [Admitted(_, "tools/call"), Start(_)] = effects
}

pub fn tool_access_policy_reads_the_request_context_test() {
  let #(_state, _ex, effects) =
    support.receive(
      reducer.init(guarded_server()),
      "admin",
      support.call("admin-call", "readonly", [#("name", json.string("Ann"))]),
    )
  let assert [Admitted(_, "tools/call"), Start(inv)] = effects
  reducer.invocation_tool(inv) |> should.equal(option.Some("readonly"))
}

// --- identity ----------------------------------------------------------------

fn discover(srv: Server(String)) -> BitArray {
  let #(_state, _ex, effects) =
    support.receive(
      reducer.init(srv),
      "ctx",
      support.request(json.string("d"), "server/discover", []),
    )
  let assert [Admitted(_, "server/discover"), Write(_, bytes), Close(_)] =
    effects
  bytes
}

pub fn with_info_and_instructions_appear_in_discover_test() {
  let bytes =
    sample_server()
    |> server.with_info("notes", "2.3.4")
    |> server.with_instructions("Call greet with a name.")
    |> discover
  let info = ["result", "_meta", "io.modelcontextprotocol/serverInfo"]
  support.at(bytes, list.append(info, ["name"]), decode.string)
  |> should.equal("notes")
  support.at(bytes, list.append(info, ["version"]), decode.string)
  |> should.equal("2.3.4")
  support.at(bytes, ["result", "instructions"], decode.string)
  |> should.equal("Call greet with a name.")
}

pub fn default_info_is_relay_without_instructions_test() {
  let bytes = discover(sample_server())
  let info = ["result", "_meta", "io.modelcontextprotocol/serverInfo"]
  support.at(bytes, list.append(info, ["name"]), decode.string)
  |> should.equal("relay")
  support.at(bytes, list.append(info, ["version"]), decode.string)
  |> should.equal("0.1.0")
  support.has(bytes, ["result", "instructions"]) |> should.be_false
}

pub fn with_info_reaches_tool_results_test() {
  let srv = sample_server() |> server.with_info("notes", "2.3.4")
  let #(state, _ex, effects) =
    support.receive(
      reducer.init(srv),
      "ctx",
      support.call("c", "greet", [#("name", json.string("Al"))]),
    )
  let assert [Admitted(_, "tools/call"), Start(inv)] = effects
  let #(_state, effects) =
    reducer.step(state, reducer.perform(inv, support.ignore_progress))
  let assert [Write(_, bytes), Close(_)] = effects
  support.at(
    bytes,
    ["result", "_meta", "io.modelcontextprotocol/serverInfo", "name"],
    decode.string,
  )
  |> should.equal("notes")
}
