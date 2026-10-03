//// The pure reducer: immediate answers, signed cursors and input rounds,
//// progress, completion context, bounded exchange records, registry
//// changes and listen streams.

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value
import relay/completion
import relay/content
import relay/prompts
import relay/reducer.{
  type Effect, type ExchangeId, type State, Admitted, Close, EndStreams,
  ExchangeClosed, Notify, Progressed, Received, RegisterTool, Start,
  UnregisterTool, Write,
}
import relay/reducer_support as support
import relay/resources
import relay/server.{type Server}
import relay/subscriptions
import relay/test_codec
import relay/tool

fn echo_tool(name: String) -> tool.Tool(String) {
  tool.define(name, test_codec.property("text", codec.string()), codec.string())
  |> tool.handle(fn(text: String) { Ok(text) })
}

fn assert_immediate(
  ex: ExchangeId,
  effects: List(Effect(String)),
  code: Int,
) -> BitArray {
  let assert [Write(written, bytes), Close(closed)] = effects
  written |> should.equal(ex)
  closed |> should.equal(ex)
  support.error_code(bytes) |> should.equal(code)
  bytes
}

// --- immediate answers -------------------------------------------------------

pub fn unknown_tool_answers_immediately_test() {
  let #(_state, ex, effects) =
    support.receive(
      reducer.init(server.new([echo_tool("echo")])),
      "ctx",
      support.call("u", "nope", [#("text", json.string("x"))]),
    )
  let bytes = assert_immediate(ex, effects, -32_602)
  support.at(bytes, ["id"], decode.string) |> should.equal("u")
}

fn needs_elicitation() -> Server(String) {
  server.new([
    tool.define(
      "ask",
      test_codec.property("text", codec.string()),
      codec.string(),
    )
    |> tool.with_required_client_capabilities(["elicitation"])
    |> tool.handle(fn(text: String) { Ok(text) }),
  ])
}

fn call_with_capabilities(capabilities: json.Json) -> BitArray {
  support.request_with_meta(
    json.string("cap"),
    "tools/call",
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", capabilities),
    ]),
    [
      #("name", json.string("ask")),
      #("arguments", json.object([#("text", json.string("hi"))])),
    ],
  )
}

pub fn missing_required_capability_answers_immediately_test() {
  let #(_state, ex, effects) =
    support.receive(
      reducer.init(needs_elicitation()),
      "ctx",
      call_with_capabilities(json.object([])),
    )
  let bytes = assert_immediate(ex, effects, -32_021)
  support.has(bytes, ["error", "data", "requiredCapabilities", "elicitation"])
  |> should.be_true

  // A client that declares the capability gets an invocation.
  let #(_state, _ex, effects) =
    support.receive(
      reducer.init(needs_elicitation()),
      "ctx",
      call_with_capabilities(json.object([#("elicitation", json.object([]))])),
    )
  let assert [Admitted(_, "tools/call"), Start(_)] = effects
}

pub fn invalid_request_state_answers_immediately_test() {
  let #(_state, ex, effects) =
    support.receive(
      reducer.init(server.new([echo_tool("echo")])),
      "ctx",
      support.request(json.string("s"), "tools/call", [
        #("name", json.string("echo")),
        #("arguments", json.object([#("text", json.string("x"))])),
        #("requestState", json.string("forged-state")),
      ]),
    )
  assert_immediate(ex, effects, -32_602)
}

// --- cursors -----------------------------------------------------------------

fn many_tools() -> List(tool.Tool(String)) {
  list.map(int_range(0, 100), fn(i) {
    echo_tool("t" <> int.to_string(1000 + i))
  })
}

fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

fn tools_page(
  state: State(String),
  cursor: Option(String),
) -> #(ExchangeId, List(Effect(String))) {
  let fields = case cursor {
    None -> []
    Some(token) -> [#("cursor", json.string(token))]
  }
  let #(_state, ex, effects) =
    support.receive(
      state,
      "ctx",
      support.request(json.string("p"), "tools/list", fields),
    )
  #(ex, effects)
}

fn page_names(
  effects: List(Effect(String)),
) -> #(List(String), Option(String)) {
  let assert [Admitted(_, "tools/list"), Write(_, bytes), Close(_)] = effects
  let names =
    support.at(
      bytes,
      ["result", "tools"],
      decode.list(decode.at(["name"], decode.string)),
    )
  let next = case support.has(bytes, ["result", "nextCursor"]) {
    True -> Some(support.at(bytes, ["result", "nextCursor"], decode.string))
    False -> None
  }
  #(names, next)
}

pub fn cursor_stays_valid_across_reducer_states_test() {
  let srv = server.new(many_tools())

  // The first page comes from one connection state...
  let #(_ex, effects) = tools_page(reducer.init(srv), None)
  let #(first, next) = page_names(effects)
  list.length(first) |> should.equal(100)
  let assert Some(cursor) = next

  // ...and its cursor is read by a fresh state of the same server, as two
  // stateless HTTP requests are.
  let #(_ex, effects) = tools_page(reducer.init(srv), Some(cursor))
  let #(second, next) = page_names(effects)
  second |> should.equal(["t1100"])
  next |> should.equal(None)
}

pub fn cursor_from_another_server_is_refused_test() {
  let #(_ex, effects) = tools_page(reducer.init(server.new(many_tools())), None)
  let #(_first, next) = page_names(effects)
  let assert Some(cursor) = next

  // The same tools in another `server.new` value sign with another key.
  let #(ex, effects) =
    tools_page(reducer.init(server.new(many_tools())), Some(cursor))
  assert_immediate(ex, effects, -32_602)

  // A forged cursor is refused too.
  let #(ex, effects) =
    tools_page(reducer.init(server.new(many_tools())), Some("bm90LWEtY3Vyc29y"))
  assert_immediate(ex, effects, -32_602)
}

pub fn cursor_is_bound_to_its_listing_test() {
  let welcome =
    prompts.prompt("welcome", [], fn(_context: String, _arguments) {
      Ok(prompts.PromptResult(None, [prompts.user_message("hi")], []))
    })
  let srv = server.new(many_tools()) |> server.with_prompts([welcome])
  let #(_ex, effects) = tools_page(reducer.init(srv), None)
  let #(_first, next) = page_names(effects)
  let assert Some(cursor) = next

  let #(_state, ex, effects) =
    support.receive(
      reducer.init(srv),
      "ctx",
      support.request(json.string("p"), "prompts/list", [
        #("cursor", json.string(cursor)),
      ]),
    )
  assert_immediate(ex, effects, -32_602)
}

// --- input rounds ------------------------------------------------------------

fn ask_tool(name: String) -> tool.Tool(String) {
  tool.define(name, test_codec.property("q", codec.string()), codec.string())
  |> tool.handle_call(fn(call, question) {
    case dict.get(tool.input_responses(call), "answer") {
      Ok(_) -> Ok(tool.complete("answered " <> question))
      Error(Nil) ->
        Ok(
          tool.request_input(
            dict.from_list([
              #(
                "answer",
                tool.InputRequest(
                  tool.Elicitation,
                  value.Object([#("message", value.String(question))]),
                ),
              ),
            ]),
          ),
        )
    }
  })
}

fn elicitation_meta() -> json.Json {
  json.object([
    #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
    #(
      "io.modelcontextprotocol/clientCapabilities",
      json.object([#("elicitation", json.object([]))]),
    ),
  ])
}

fn ask(
  state: State(String),
  tool_name: String,
  request_state: Option(String),
) -> #(State(String), ExchangeId, List(Effect(String))) {
  let continuation = case request_state {
    None -> []
    Some(token) -> [
      #("requestState", json.string(token)),
      #(
        "inputResponses",
        json.object([
          #("answer", json.object([#("action", json.string("accept"))])),
        ]),
      ),
    ]
  }
  support.receive(
    state,
    "ctx",
    support.request_with_meta(
      json.string("ask"),
      "tools/call",
      elicitation_meta(),
      [
        #("name", json.string(tool_name)),
        #("arguments", json.object([#("q", json.string("why"))])),
        ..continuation
      ],
    ),
  )
}

fn first_round(srv: Server(String), tool_name: String) -> String {
  let #(state, _ex, effects) = ask(reducer.init(srv), tool_name, None)
  let assert [Admitted(_, "tools/call"), Start(inv)] = effects
  let #(_state, effects) =
    reducer.step(state, reducer.perform(inv, support.ignore_progress))
  let assert [Write(_, bytes), Close(_)] = effects
  support.at(bytes, ["result", "resultType"], decode.string)
  |> should.equal("input_required")
  support.at(
    bytes,
    ["result", "inputRequests", "answer", "method"],
    decode.string,
  )
  |> should.equal("elicitation/create")
  support.at(bytes, ["result", "requestState"], decode.string)
}

pub fn request_state_stays_valid_across_reducer_states_test() {
  let srv = server.new([ask_tool("ask")])
  let request_state = first_round(srv, "ask")

  // The second round reaches a fresh state of the same server.
  let #(state, _ex, effects) =
    ask(reducer.init(srv), "ask", Some(request_state))
  let assert [Admitted(_, "tools/call"), Start(inv)] = effects
  let #(_state, effects) =
    reducer.step(state, reducer.perform(inv, support.ignore_progress))
  let assert [Write(_, bytes), Close(_)] = effects
  support.at(bytes, ["result", "structuredContent"], decode.string)
  |> should.equal("answered why")
}

pub fn request_state_from_another_server_is_refused_test() {
  let request_state = first_round(server.new([ask_tool("ask")]), "ask")
  let #(_state, ex, effects) =
    ask(reducer.init(server.new([ask_tool("ask")])), "ask", Some(request_state))
  assert_immediate(ex, effects, -32_602)
}

pub fn request_state_is_bound_to_its_tool_test() {
  let srv = server.new([ask_tool("ask"), ask_tool("other")])
  let request_state = first_round(srv, "ask")
  let #(_state, ex, effects) =
    ask(reducer.init(srv), "other", Some(request_state))
  assert_immediate(ex, effects, -32_602)
}

// --- progress ----------------------------------------------------------------

fn start_with_meta(
  request_meta: json.Json,
) -> #(State(String), ExchangeId, reducer.Invocation(String)) {
  let #(state, ex, effects) =
    support.receive(
      reducer.init(server.new([echo_tool("echo")])),
      "ctx",
      support.request_with_meta(
        json.string("prog"),
        "tools/call",
        request_meta,
        [
          #("name", json.string("echo")),
          #("arguments", json.object([#("text", json.string("x"))])),
        ],
      ),
    )
  let assert [Admitted(_, "tools/call"), Start(inv)] = effects
  #(state, ex, inv)
}

pub fn progress_encodes_progress_total_and_message_test() {
  let #(state, ex, inv) =
    start_with_meta(support.meta([#("progressToken", json.string("tok"))]))
  let id = reducer.invocation_id(inv)

  let #(state, effects) =
    reducer.step(state, Progressed(id, 0.5, Some(2.0), Some("half")))
  let assert [Write(written, bytes)] = effects
  written |> should.equal(ex)
  support.text(bytes)
  |> should.equal(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":"
    <> "{\"progressToken\":\"tok\",\"progress\":0.5,\"total\":2,\"message\":\"half\"}}",
  )

  // Equal and lower progress is dropped.
  let #(state, effects) = reducer.step(state, Progressed(id, 0.5, None, None))
  effects |> should.equal([])
  let #(state, effects) = reducer.step(state, Progressed(id, 0.25, None, None))
  effects |> should.equal([])

  // Higher progress is written again, without the optional fields.
  let #(state, effects) = reducer.step(state, Progressed(id, 1.5, None, None))
  let assert [Write(_, bytes)] = effects
  support.at(bytes, ["params", "progress"], decode.float)
  |> should.equal(1.5)
  support.has(bytes, ["params", "total"]) |> should.be_false
  support.has(bytes, ["params", "message"]) |> should.be_false

  // Nothing is written after the invocation finished.
  let #(state, _) =
    reducer.step(state, reducer.perform(inv, support.ignore_progress))
  let #(_state, effects) = reducer.step(state, Progressed(id, 9.0, None, None))
  effects |> should.equal([])
}

pub fn negative_progress_is_dropped_test() {
  let #(state, _ex, inv) =
    start_with_meta(support.meta([#("progressToken", json.int(1))]))
  let #(_state, effects) =
    reducer.step(
      state,
      Progressed(reducer.invocation_id(inv), -1.0, None, None),
    )
  effects |> should.equal([])
}

pub fn progress_without_client_token_writes_nothing_test() {
  let #(state, _ex, inv) = start_with_meta(support.meta([]))
  let #(_state, effects) =
    reducer.step(
      state,
      Progressed(reducer.invocation_id(inv), 1.0, Some(2.0), Some("x")),
    )
  effects |> should.equal([])
}

pub fn perform_forwards_handler_progress_reports_test() {
  let reporter =
    tool.define(
      "work",
      test_codec.property("text", codec.string()),
      codec.string(),
    )
    |> tool.handle_call(fn(call, text) {
      tool.report_progress(call, 1.0, Some(3.0), Some("one"))
      tool.report_progress(call, 2.0, None, None)
      Ok(tool.complete(text))
    })
  let #(_state, _ex, effects) =
    support.receive(
      reducer.init(server.new([reporter])),
      "ctx",
      support.call("w", "work", [#("text", json.string("done"))]),
    )
  let assert [Admitted(_, "tools/call"), Start(inv)] = effects
  let reports = process.new_subject()
  let _ =
    reducer.perform(inv, fn(progress, total, message) {
      process.send(reports, #(progress, total, message))
    })
  process.receive(reports, 100)
  |> should.equal(Ok(#(1.0, Some(3.0), Some("one"))))
  process.receive(reports, 100) |> should.equal(Ok(#(2.0, None, None)))
}

// --- completion --------------------------------------------------------------

pub fn completion_handler_receives_spec_shaped_context_test() {
  let complete =
    completion.completion(fn(_context: String, request: completion.Request) {
      let assert completion.PromptReference(name) = request.reference
      let lang = dict.get(request.context, "lang")
      case lang {
        Ok(lang) ->
          Ok(completion.values([name, request.argument, request.value, lang]))
        Error(Nil) -> Error("no lang")
      }
    })
  let srv = server.new([]) |> server.with_completion(complete)
  let #(state, _ex, effects) =
    support.receive(
      reducer.init(srv),
      "ctx",
      support.request(json.string("c"), "completion/complete", [
        #(
          "ref",
          json.object([
            #("type", json.string("ref/prompt")),
            #("name", json.string("welcome")),
          ]),
        ),
        #(
          "argument",
          json.object([
            #("name", json.string("name")),
            #("value", json.string("a")),
          ]),
        ),
        #(
          "context",
          json.object([
            #("arguments", json.object([#("lang", json.string("gleam"))])),
          ]),
        ),
      ]),
    )
  let assert [Admitted(_, "completion/complete"), Start(inv)] = effects
  let #(_state, effects) =
    reducer.step(state, reducer.perform(inv, support.ignore_progress))
  let assert [Write(_, bytes), Close(_)] = effects
  support.at(
    bytes,
    ["result", "completion", "values"],
    decode.list(decode.string),
  )
  |> should.equal(["welcome", "name", "a", "gleam"])
}

// --- bounded exchange records ------------------------------------------------

fn discover_frame() -> BitArray {
  support.request(json.string("d"), "server/discover", [])
}

fn close_many(state: State(String), count: Int) -> State(String) {
  case count <= 0 {
    True -> state
    False -> {
      let #(state, _) =
        reducer.step(state, ExchangeClosed(reducer.new_exchange_id()))
      close_many(state, count - 1)
    }
  }
}

pub fn closed_exchange_records_are_bounded_test() {
  let state = reducer.init(server.new([echo_tool("echo")]))
  let #(state, old, _) = support.receive(state, "ctx", discover_frame())

  // While the record is kept, a repeated frame on the exchange is ignored.
  let #(state, effects) =
    reducer.step(state, Received(old, "ctx", discover_frame(), None))
  effects |> should.equal([])

  // Close 10,000 more exchanges: the reducer drops its oldest records.
  let state = close_many(state, 10_000)
  let #(state, recent, _) = support.receive(state, "ctx", discover_frame())

  // The pruned record no longer suppresses the frame...
  let #(state, effects) =
    reducer.step(state, Received(old, "ctx", discover_frame(), None))
  let assert [Admitted(_, "server/discover"), Write(_, _), Close(_)] = effects

  // ...while a recent one still does.
  let #(_state, effects) =
    reducer.step(state, Received(recent, "ctx", discover_frame(), None))
  effects |> should.equal([])
}

// --- listen streams ----------------------------------------------------------

fn open_stream(
  state: State(String),
  id: String,
  filter: List(#(String, json.Json)),
) -> #(State(String), ExchangeId, BitArray) {
  let #(state, ex, effects) =
    support.receive(state, "ctx", support.listen(id, json.object(filter)))
  let assert [Admitted(admitted, "subscriptions/listen"), Write(written, ack)] =
    effects
  admitted |> should.equal(ex)
  written |> should.equal(ex)
  support.at(ack, ["method"], decode.string)
  |> should.equal("notifications/subscriptions/acknowledged")
  #(state, ex, ack)
}

fn stream_write(
  effects: List(Effect(String)),
) -> #(ExchangeId, String, String) {
  let assert [Write(ex, bytes)] = effects
  #(
    ex,
    support.at(bytes, ["method"], decode.string),
    support.at(
      bytes,
      ["params", "_meta", "io.modelcontextprotocol/subscriptionId"],
      decode.string,
    ),
  )
}

pub fn registry_changes_notify_listening_streams_test() {
  let state = reducer.init(server.new([echo_tool("echo")]))
  let #(state, tools_ex, ack) =
    open_stream(state, "tools-sub", [#("toolsListChanged", json.bool(True))])
  support.at(ack, ["params", "notifications", "toolsListChanged"], decode.bool)
  |> should.be_true
  let #(state, _prompts_ex, _) =
    open_stream(state, "prompts-sub", [#("promptsListChanged", json.bool(True))])
  reducer.open_streams(state) |> should.equal(2)

  // Registering a tool tells only the stream that asked for tool changes.
  let #(state, effects) = reducer.step(state, RegisterTool(echo_tool("added")))
  stream_write(effects)
  |> should.equal(#(tools_ex, "notifications/tools/list_changed", "tools-sub"))
  server.has_tool(reducer.server(state), "added") |> should.be_true

  // A duplicate registration changes nothing and tells no one.
  let #(state, effects) = reducer.step(state, RegisterTool(echo_tool("added")))
  effects |> should.equal([])

  // Unregistering an existing tool notifies; an unknown name does not.
  let #(state, effects) = reducer.step(state, UnregisterTool("added"))
  stream_write(effects)
  |> should.equal(#(tools_ex, "notifications/tools/list_changed", "tools-sub"))
  server.has_tool(reducer.server(state), "added") |> should.be_false
  let #(_state, effects) = reducer.step(state, UnregisterTool("missing"))
  effects |> should.equal([])
}

pub fn end_streams_writes_listen_results_and_closes_each_stream_test() {
  let state = reducer.init(server.new([echo_tool("echo")]))
  let #(state, first, _) =
    open_stream(state, "one", [#("toolsListChanged", json.bool(True))])
  let #(state, second, _) =
    open_stream(state, "two", [#("toolsListChanged", json.bool(True))])

  let #(state, effects) = reducer.step(state, EndStreams)
  list.length(effects) |> should.equal(4)
  let results =
    list.filter_map(effects, fn(effect) {
      case effect {
        Write(ex, bytes) -> {
          support.at(bytes, ["result", "resultType"], decode.string)
          |> should.equal("complete")
          Ok(#(ex, support.at(bytes, ["id"], decode.string)))
        }
        _ -> Error(Nil)
      }
    })
  set.from_list(results)
  |> should.equal(set.from_list([#(first, "one"), #(second, "two")]))
  let closed =
    list.filter_map(effects, fn(effect) {
      case effect {
        Close(ex) -> Ok(ex)
        _ -> Error(Nil)
      }
    })
  set.from_list(closed) |> should.equal(set.from_list([first, second]))
  reducer.open_streams(state) |> should.equal(0)

  // Ended streams receive nothing more.
  let #(state, effects) =
    reducer.step(state, Notify(subscriptions.ToolsListChanged))
  effects |> should.equal([])
  let #(_state, effects) = reducer.step(state, EndStreams)
  effects |> should.equal([])
}

fn memo(uri: String) -> resources.Resource(String) {
  resources.static(uri, uri, fn(_context: String, uri) {
    Ok([content.text_resource(uri, "body")])
  })
}

pub fn resource_updated_reaches_only_subscribed_streams_test() {
  let srv =
    server.new([])
    |> server.with_resources([memo("memo://a"), memo("memo://b")])
  let state = reducer.init(srv)
  let #(state, a_ex, ack) =
    open_stream(state, "a", [
      #("resourceSubscriptions", json.array(["memo://a"], json.string)),
    ])
  support.at(
    ack,
    ["params", "notifications", "resourceSubscriptions"],
    decode.list(decode.string),
  )
  |> should.equal(["memo://a"])
  let #(state, b_ex, _) =
    open_stream(state, "b", [
      #("resourceSubscriptions", json.array(["memo://b"], json.string)),
    ])
  let #(state, _tools_ex, _) =
    open_stream(state, "t", [#("toolsListChanged", json.bool(True))])

  let #(state, effects) =
    reducer.step(state, Notify(subscriptions.ResourceUpdated("memo://a")))
  let assert [Write(written, bytes)] = effects
  written |> should.equal(a_ex)
  support.at(bytes, ["method"], decode.string)
  |> should.equal("notifications/resources/updated")
  support.at(bytes, ["params", "uri"], decode.string)
  |> should.equal("memo://a")
  support.at(
    bytes,
    ["params", "_meta", "io.modelcontextprotocol/subscriptionId"],
    decode.string,
  )
  |> should.equal("a")

  // An unsubscribed URI reaches no stream.
  let #(state, effects) =
    reducer.step(state, Notify(subscriptions.ResourceUpdated("memo://c")))
  effects |> should.equal([])

  // A closed stream receives nothing more.
  let #(state, effects) = reducer.step(state, ExchangeClosed(b_ex))
  effects |> should.equal([Close(b_ex)])
  reducer.open_streams(state) |> should.equal(2)
  let #(_state, effects) =
    reducer.step(state, Notify(subscriptions.ResourceUpdated("memo://b")))
  effects |> should.equal([])
}

pub fn resource_subscriptions_need_a_server_with_resources_test() {
  let state = reducer.init(server.new([echo_tool("echo")]))
  let #(state, _ex, ack) =
    open_stream(state, "a", [
      #("resourceSubscriptions", json.array(["memo://a"], json.string)),
    ])
  support.has(ack, ["params", "notifications", "resourceSubscriptions"])
  |> should.be_false
  let #(_state, effects) =
    reducer.step(state, Notify(subscriptions.ResourceUpdated("memo://a")))
  effects |> should.equal([])
}

pub fn cancelling_a_stream_closes_it_test() {
  let state = reducer.init(server.new([echo_tool("echo")]))
  let #(state, stream, _) =
    open_stream(state, "s", [#("toolsListChanged", json.bool(True))])
  let #(state, cancel_ex, effects) =
    support.receive(state, "ctx", support.cancel("s"))
  effects |> should.equal([Close(stream), Close(cancel_ex)])
  reducer.open_streams(state) |> should.equal(0)
  let #(_state, effects) = reducer.step(state, RegisterTool(echo_tool("new")))
  effects |> should.equal([])
}
