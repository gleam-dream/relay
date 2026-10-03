import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/number
import json/blueprint/value
import relay/client
import relay/content
import relay/internal/protocol/v2026_07_28 as v2026
import relay/reducer
import relay/server
import relay/test_codec
import relay/testing
import relay/tool
import sinal/correlation

@external(erlang, "relay_ffi", "rescue_run")
fn rescue(f: fn() -> a) -> Result(a, String)

fn text_input(name: String) -> codec.Codec(String) {
  test_codec.property(name, codec.string())
}

fn connect_with_input(srv: server.Server(context), context: context) {
  let assert Ok(peer) =
    client.in_process(srv, context)
    |> client.with_input_methods([tool.Elicitation])
    |> client.connect
  peer
}

fn elicitation(message: String) -> tool.InputRequest {
  tool.InputRequest(
    tool.Elicitation,
    value.Object([#("message", value.String(message))]),
  )
}

// --- definition admission ----------------------------------------------------

pub fn described_input_preserves_object_root_admission_test() {
  let input =
    test_codec.property(
      "city",
      codec.describe(codec.string(), "City to look up"),
    )
    |> codec.describe("Weather request")
  tool.try_define("described", input, codec.string()) |> should.be_ok
  tool.try_define(
    "described",
    codec.describe(codec.string(), "Plain text"),
    codec.string(),
  )
  |> should.equal(Error(tool.InputSchemaNotObject("described", "string")))
}

pub fn any_value_root_input_is_not_an_object_test() {
  tool.try_define("any_input", codec.value(), codec.string())
  |> should.equal(Error(tool.InputSchemaNotObject("any_input", "any")))
  tool.try_define_content("any_input", codec.value())
  |> should.equal(Error(tool.InputSchemaNotObject("any_input", "any")))
}

pub fn any_value_field_input_is_admitted_test() {
  let input = test_codec.property("payload", codec.value())
  tool.try_define("any_field", input, codec.string()) |> should.be_ok
}

pub fn invalid_tool_name_test() {
  tool.try_define("", text_input("a"), codec.string())
  |> should.equal(Error(tool.EmptyName))
  tool.try_define("tool name with spaces", text_input("a"), codec.string())
  |> should.equal(
    Error(tool.InvalidNameCharacter("tool name with spaces", " ")),
  )
  tool.try_define("bad\nnewline", text_input("a"), codec.string())
  |> should.equal(Error(tool.InvalidNameCharacter("bad\nnewline", "\n")))
  tool.try_define("bad\u{0000}null", text_input("a"), codec.string())
  |> should.equal(
    Error(tool.InvalidNameCharacter("bad\u{0000}null", "\u{0000}")),
  )
  tool.try_define("ns/tool.v1_beta-2", text_input("a"), codec.string())
  |> should.be_ok
}

pub fn primitive_root_input_schema_rejected_test() {
  tool.try_define("primitive_input", codec.int(), codec.string())
  |> should.equal(
    Error(tool.InputSchemaNotObject("primitive_input", "integer")),
  )
  tool.try_define_content("primitive_input", codec.int())
  |> should.equal(
    Error(tool.InputSchemaNotObject("primitive_input", "integer")),
  )
}

pub fn missing_output_schema_admission_rejection_test() {
  let broken_codec =
    codec.custom(
      encode: fn(_x: String) { Ok(value.String("ok")) },
      decode: fn(_v: value.Value) { Ok("ok") },
      schema: None,
      placeholder: "ok",
    )
  tool.try_define("bad_schema_tool", text_input("in"), broken_codec)
  |> should.equal(Error(tool.MissingOutputSchema("bad_schema_tool")))
}

pub fn try_define_returns_every_define_error_test() {
  let schemaless =
    codec.custom(
      encode: fn(_x: String) { Ok(value.String("ok")) },
      decode: fn(_v: value.Value) { Ok("ok") },
      schema: None,
      placeholder: "ok",
    )
  let long = string.repeat("a", 129)
  tool.try_define("", text_input("a"), codec.string())
  |> should.equal(Error(tool.EmptyName))
  tool.try_define(long, text_input("a"), codec.string())
  |> should.equal(Error(tool.NameTooLong(long, 128, 129)))
  tool.try_define(string.repeat("a", 128), text_input("a"), codec.string())
  |> should.be_ok
  tool.try_define("bad*name", text_input("a"), codec.string())
  |> should.equal(Error(tool.InvalidNameCharacter("bad*name", "*")))
  tool.try_define("no_input_schema", schemaless, codec.string())
  |> should.equal(Error(tool.MissingInputSchema("no_input_schema")))
  tool.try_define_content("no_input_schema", schemaless)
  |> should.equal(Error(tool.MissingInputSchema("no_input_schema")))
  tool.try_define("list_input", codec.list(codec.string()), codec.string())
  |> should.equal(Error(tool.InputSchemaNotObject("list_input", "list")))
  tool.try_define("no_output_schema", text_input("a"), schemaless)
  |> should.equal(Error(tool.MissingOutputSchema("no_output_schema")))
}

pub fn describe_define_error_mentions_the_name_test() {
  [
    tool.NameTooLong("long_name", 128, 200),
    tool.InvalidNameCharacter("star*name", "*"),
    tool.MissingInputSchema("schemaless"),
    tool.InputSchemaNotObject("primitive", "integer"),
    tool.MissingOutputSchema("no_output"),
    tool.OutputSchemaNotObject("bad_output", "string"),
  ]
  |> list.each(fn(error) {
    let described = tool.describe_define_error(error)
    let name = case error {
      tool.NameTooLong(name, ..)
      | tool.InvalidNameCharacter(name, ..)
      | tool.MissingInputSchema(name)
      | tool.InputSchemaNotObject(name, ..)
      | tool.MissingOutputSchema(name)
      | tool.OutputSchemaNotObject(name, ..) -> name
      tool.EmptyName -> ""
    }
    string.contains(described, "\"" <> name <> "\"") |> should.be_true
  })
  tool.describe_define_error(tool.InvalidNameCharacter("star*name", "*"))
  |> string.contains("\"*\"")
  |> should.be_true
  tool.describe_define_error(tool.EmptyName)
  |> string.contains("empty")
  |> should.be_true
}

pub fn define_panics_on_definition_mistakes_test() {
  rescue(fn() { tool.define("bad name", text_input("a"), codec.string()) })
  |> should.be_error
  rescue(fn() { tool.define("primitive", codec.int(), codec.string()) })
  |> should.be_error
  rescue(fn() { tool.define_content("", text_input("a")) })
  |> should.be_error
  rescue(fn() { tool.define_content("primitive", codec.string()) })
  |> should.be_error
  rescue(fn() { tool.define("fine", text_input("a"), codec.string()) })
  |> should.be_ok
}

// --- metadata ----------------------------------------------------------------

pub fn definition_setters_show_in_declaration_and_wire_test() {
  let icon =
    content.Icon(
      src: "https://example.com/lookup.png",
      mime_type: Some("image/png"),
      sizes: ["48x48"],
      theme: Some(content.DarkTheme),
    )
  let meta = [#("example.com/owner", value.String("records"))]
  let definition =
    tool.define("declared", text_input("input"), codec.string())
    |> tool.with_description("Looks up a record")
    |> tool.with_title("Lookup")
    |> tool.with_read_only_hint(True)
    |> tool.with_destructive_hint(False)
    |> tool.with_idempotent_hint(True)
    |> tool.with_open_world_hint(False)
    |> tool.with_icons([icon])
    |> tool.with_meta(meta)
  let declaration = tool.declaration(definition)
  declaration.name |> should.equal("declared")
  declaration.title |> should.equal(Some("Lookup"))
  declaration.description |> should.equal(Some("Looks up a record"))
  declaration.annotations
  |> should.equal(tool.ToolAnnotations(
    title: None,
    read_only_hint: Some(True),
    destructive_hint: Some(False),
    idempotent_hint: Some(True),
    open_world_hint: Some(False),
  ))
  declaration.icons |> should.equal([icon])
  declaration.meta |> should.equal(meta)

  let encoded = json.to_string(v2026.tool_declaration_to_json(declaration))
  string.contains(encoded, "\"title\":\"Lookup\"") |> should.be_true
  string.contains(encoded, "\"description\":\"Looks up a record\"")
  |> should.be_true
  string.contains(encoded, "\"readOnlyHint\":true") |> should.be_true
  string.contains(encoded, "\"destructiveHint\":false") |> should.be_true
  string.contains(encoded, "\"idempotentHint\":true") |> should.be_true
  string.contains(encoded, "\"openWorldHint\":false") |> should.be_true
  string.contains(encoded, "\"src\":\"https://example.com/lookup.png\"")
  |> should.be_true
  string.contains(encoded, "\"theme\":\"dark\"") |> should.be_true
  string.contains(encoded, "\"_meta\":{\"example.com/owner\":\"records\"}")
  |> should.be_true

  // The same declaration reaches a client through tools/list.
  let peer =
    testing.connect(
      server.new([tool.handle(definition, fn(input) { Ok(input) })]),
      Nil,
    )
  let assert Ok([listed]) = client.list_tools(peer)
  listed.title |> should.equal(Some("Lookup"))
  listed.annotations |> should.equal(declaration.annotations)
  listed.icons |> should.equal([icon])
  listed.meta |> should.equal(meta)
  client.close(peer)
}

pub fn unset_hints_are_omitted_test() {
  let bare = tool.define("bare", text_input("input"), codec.string())
  let declaration = tool.declaration(bare)
  declaration.title |> should.equal(None)
  declaration.description |> should.equal(None)
  declaration.annotations
  |> should.equal(tool.ToolAnnotations(None, None, None, None, None))
  let encoded = json.to_string(v2026.tool_declaration_to_json(declaration))
  string.contains(encoded, "annotations") |> should.be_false
  string.contains(encoded, "icons") |> should.be_false
  string.contains(encoded, "_meta") |> should.be_false
  string.contains(encoded, "\"title\"") |> should.be_false

  let partial =
    bare
    |> tool.with_read_only_hint(True)
    |> tool.declaration
    |> v2026.tool_declaration_to_json
    |> json.to_string
  string.contains(partial, "\"readOnlyHint\":true") |> should.be_true
  string.contains(partial, "destructiveHint") |> should.be_false
  string.contains(partial, "idempotentHint") |> should.be_false
  string.contains(partial, "openWorldHint") |> should.be_false
}

pub fn definition_accessors_test() {
  let structured = tool.define("structured", text_input("input"), codec.int())
  tool.name(structured) |> should.equal("structured")
  let assert Some(output) = tool.output_codec(structured)
  codec.encode(output, 7)
  |> should.equal(Ok(value.Number(must_int(7))))
  codec.encode(tool.input_codec(structured), "x")
  |> should.equal(Ok(value.Object([#("input", value.String("x"))])))

  let content_only = tool.define_content("content", text_input("input"))
  tool.name(content_only) |> should.equal("content")
  tool.output_codec(content_only) |> should.equal(None)
  tool.declaration(content_only).output_schema |> should.equal(None)
}

pub fn primitive_output_schema_is_a_valid_json_schema_test() {
  let definition =
    tool.define("primitive_output_tool", text_input("input"), codec.string())
  let assert Some(value.Object(members)) =
    tool.declaration(definition).output_schema
  list.key_find(members, "type") |> should.equal(Ok(value.String("string")))
}

pub fn input_contract_validates_arguments_test() {
  let definition = tool.define("weather", text_input("city"), codec.string())
  let assert Ok(input_contract) =
    tool.input_contract(tool.declaration(definition))
  let good = value.Object([#("city", value.String("Lisbon"))])
  let assert Ok(validated) = contract.validate(input_contract, good)
  contract.value(validated) |> should.equal(good)
  contract.validate(input_contract, value.Object([])) |> should.be_error
  contract.validate(
    input_contract,
    value.Object([#("city", value.Number(must_int(1)))]),
  )
  |> should.be_error
}

pub fn with_required_client_capabilities_refuses_undeclared_clients_test() {
  let calls = process.new_subject()
  let definition =
    tool.define("needs_sampling", text_input("input"), codec.string())
    |> tool.with_required_client_capabilities(["sampling"])
  let srv =
    server.new([
      tool.handle(definition, fn(input) {
        process.send(calls, input)
        Ok(input)
      }),
    ])
  let peer = testing.connect(srv, Nil)
  let assert Error(client.RpcError(-32_021, _, Some(_))) =
    client.call(peer, definition, "x")
  process.receive(calls, 0) |> should.be_error
  client.close(peer)

  let assert Ok(sampling_peer) =
    client.in_process(srv, Nil)
    |> client.with_input_methods([tool.Sampling])
    |> client.connect
  let assert Ok(client.Succeeded("x", _)) =
    client.call(sampling_peer, definition, "x")
  client.close(sampling_peer)
}

// --- explicit input schema ---------------------------------------------------

pub fn schema_override_changes_discovery_but_codec_still_validates_test() {
  let override =
    value.Object([
      #("type", value.String("object")),
      #("x-mcp-header", value.String("X-Trace")),
    ])
  let definition =
    tool.define("overridden", text_input("input"), codec.string())
    |> tool.with_input_schema(override)
  tool.declaration(definition).input_schema |> should.equal(override)
  let peer =
    testing.connect(
      server.new([tool.handle(definition, fn(input) { Ok(input) })]),
      Nil,
    )
  let assert Ok([listed]) = client.list_tools(peer)
  listed.input_schema |> should.equal(override)
  let assert Error(client.RpcError(-32_602, _, _)) =
    client.call_discovered(peer, listed, value.Object([]))
  let assert Ok(client.Succeeded(value.String("go"), _)) =
    client.call_discovered(
      peer,
      listed,
      value.Object([#("input", value.String("go"))]),
    )
  client.close(peer)
}

pub fn with_input_schema_panics_on_a_non_object_test() {
  let definition =
    tool.define("overridden", text_input("input"), codec.string())
  rescue(fn() { tool.with_input_schema(definition, value.String("bad")) })
  |> should.be_error
  let content_definition = tool.define_content("content", text_input("input"))
  rescue(fn() { tool.with_input_schema(content_definition, value.Array([])) })
  |> should.be_error
}

pub fn content_definition_override_and_input_round_test() {
  let override = value.Object([#("type", value.String("object"))])
  let definition =
    tool.define_content("content_round", text_input("input"))
    |> tool.with_input_schema(override)
  let bound =
    tool.handle_call(definition, fn(call, _input) {
      case dict.get(tool.input_responses(call), "confirm") {
        Error(Nil) ->
          Ok(
            tool.request_input(
              dict.from_list([#("confirm", elicitation("Proceed?"))]),
            ),
          )
        Ok(answer) ->
          Ok(tool.complete([content.text("done: " <> value.to_string(answer))]))
      }
    })
  tool.tool_declaration(bound).input_schema |> should.equal(override)
  let peer = connect_with_input(server.new([bound]), Nil)
  let assert Ok([listed]) = client.list_tools(peer)
  let assert Error(client.RpcError(-32_602, _, _)) =
    client.call_discovered(peer, listed, value.Object([]))
  let assert Ok(client.InputRequired(continuation, requests)) =
    client.call(peer, definition, "go")
  dict.keys(requests) |> should.equal(["confirm"])
  let assert Ok(client.Succeeded(blocks, _)) =
    client.resume(
      continuation,
      dict.from_list([
        #("confirm", json.object([#("action", json.string("accept"))])),
      ]),
    )
  blocks |> should.equal([content.text("done: {\"action\":\"accept\"}")])
  client.close(peer)
}

// --- handlers through a server -----------------------------------------------

pub fn heterogeneous_tools_share_one_server_test() {
  let echo_definition =
    tool.define("echo", text_input("message"), codec.string())
    |> tool.with_description("Echoes input text")
  let math_definition =
    tool.define("add", test_codec.property("amount", codec.int()), codec.int())
    |> tool.with_description("Adds 1 to integer")
  let echo_tool =
    tool.handle_with_error_renderer(
      echo_definition,
      fn(message: String) { Ok("echo: " <> message) },
      fn(_: Nil) { tool.error_message("echo failed") },
    )
  let math =
    tool.handle_with_error_renderer(
      math_definition,
      fn(n: Int) { Ok(n + 1) },
      fn(error: String) { tool.error_message(error) },
    )
  let srv = server.new([echo_tool, math])
  server.tools(srv)
  |> list.map(fn(declaration) { declaration.name })
  |> should.equal(["echo", "add"])
  let peer = testing.connect(srv, Nil)
  let assert Ok(listed) = client.list_tools(peer)
  list.length(listed) |> should.equal(2)
  let assert Ok(client.Succeeded("echo: hello", _)) =
    client.call(peer, echo_definition, "hello")
  let assert Ok(client.Succeeded(42, _)) =
    client.call(peer, math_definition, 41)
  client.close(peer)
}

pub fn duplicate_tool_name_rejected_test() {
  let first =
    tool.define("duplicate", text_input("a"), codec.string())
    |> tool.handle(fn(input) { Ok(input) })
  let second =
    tool.define("duplicate", test_codec.property("b", codec.int()), codec.int())
    |> tool.handle(fn(n) { Ok(n) })
  rescue(fn() { server.new([first, second]) }) |> should.be_error
  server.new([first])
  |> server.register_tool(second)
  |> should.equal(Error(server.DuplicateTool("duplicate")))
}

pub fn unknown_tool_call_test() {
  let ghost = tool.define("ghost", text_input("a"), codec.string())
  let peer = testing.connect(server.new([]), Nil)
  let assert Error(client.RpcError(-32_602, _, _)) =
    client.call(peer, ghost, "boo")
  client.close(peer)
}

pub fn invalid_input_arguments_test() {
  let calls = process.new_subject()
  let definition =
    tool.define("strict_input", text_input("msg"), codec.string())
  let peer =
    testing.connect(
      server.new([
        tool.handle(definition, fn(msg) {
          process.send(calls, msg)
          Ok(msg)
        }),
      ]),
      Nil,
    )
  let assert Error(client.RpcError(-32_602, _, _)) =
    client.call_discovered(
      peer,
      tool.declaration(definition),
      value.Object([#("msg", value.Number(must_int(99)))]),
    )
  process.receive(calls, 0) |> should.be_error
  client.close(peer)
}

pub fn application_failure_renderer_publishes_its_text_test() {
  let definition = tool.define("app_fail", text_input("in"), codec.string())
  let bound =
    tool.handle_with_error_renderer(
      definition,
      fn(_in: String) { Error(404) },
      fn(code) {
        case
          codec.encode_json(test_codec.property("err_code", codec.int()), code)
        {
          Ok(text) -> tool.error_message(text)
          Error(_) -> tool.error_message("Tool execution failed.")
        }
      },
    )
  let peer = testing.connect(server.new([bound]), Nil)
  client.call(peer, definition, "x")
  |> should.equal(
    Ok(client.ToolFailed([content.text("{\"err_code\":404}")], None)),
  )
  client.close(peer)
}

pub fn error_renderer_can_fall_back_when_encoding_fails_test() {
  let range_codec = codec.integer_between(0, 10)
  let definition =
    tool.define("range_err_tool", text_input("dummy"), codec.string())
  let bound =
    tool.handle_with_error_renderer(
      definition,
      fn(_d: String) { Error(999) },
      fn(code) {
        case codec.encode_json(range_codec, code) {
          Ok(text) -> tool.error_message(text)
          Error(_) -> tool.error_message("Tool execution failed.")
        }
      },
    )
  let peer = testing.connect(server.new([bound]), Nil)
  client.call(peer, definition, "hi")
  |> should.equal(
    Ok(client.ToolFailed([content.text("Tool execution failed.")], None)),
  )
  client.close(peer)
}

pub fn error_with_publishes_content_and_structured_value_test() {
  let definition =
    tool.define("detailed_fail", text_input("in"), codec.string())
  let detail = value.Object([#("code", value.String("quota"))])
  let bound =
    tool.handle_with_error_renderer(
      definition,
      fn(_in: String) { Error("quota") },
      fn(reason) {
        tool.error_with(
          [content.text("over " <> reason), content.text("try later")],
          Some(detail),
        )
      },
    )
  let peer = testing.connect(server.new([bound]), Nil)
  client.call(peer, definition, "x")
  |> should.equal(
    Ok(client.ToolFailed(
      [content.text("over quota"), content.text("try later")],
      Some(detail),
    )),
  )
  client.close(peer)
}

pub fn handle_hides_the_handler_error_test() {
  let definition =
    tool.define("plain_error", text_input("input"), codec.string())
  let peer =
    testing.connect(
      server.new([
        tool.handle(definition, fn(_input) { Error("secret detail") }),
      ]),
      Nil,
    )
  let assert Ok(client.ToolFailed(blocks, None)) =
    client.call(peer, definition, "x")
  blocks |> should.equal([content.text("Tool execution failed.")])
  client.close(peer)
}

pub fn exact_blueprint_number_preservation_test() {
  let definition =
    tool.define(
      "exact_num",
      test_codec.property("num", codec.number()),
      codec.number(),
    )
  let peer =
    testing.connect(server.new([tool.handle(definition, fn(n) { Ok(n) })]), Nil)
  // A 50-digit number that would lose precision as an IEEE 754 float.
  let assert Ok(parsed) =
    number.parse(
      "12345678901234567890123456789012345678901234567890",
      number.limits(1024, 100, 1000),
    )
  let assert Ok(client.Succeeded(output, _)) =
    client.call_discovered(
      peer,
      tool.declaration(definition),
      value.Object([#("num", value.Number(parsed))]),
    )
  output |> should.equal(value.Number(parsed))
  let assert Ok(client.Succeeded(typed, _)) =
    client.call(peer, definition, parsed)
  typed |> should.equal(parsed)
  client.close(peer)
}

pub fn invalid_output_encoding_is_an_internal_error_test() {
  let definition =
    tool.define("range_tool", text_input("dummy"), codec.integer_between(0, 10))
  let peer =
    testing.connect(
      server.new([tool.handle(definition, fn(_d) { Ok(999) })]),
      Nil,
    )
  let assert Error(client.RpcError(-32_603, _, _)) =
    client.call(peer, definition, "hi")
  client.close(peer)
}

pub fn complete_mirrors_structured_output_as_text_test() {
  let text_definition =
    tool.define("mirror_text", text_input("in"), codec.string())
  let object_definition =
    tool.define(
      "mirror_object",
      text_input("in"),
      test_codec.property("count", codec.int()),
    )
  let srv =
    server.new([
      tool.handle_call(text_definition, fn(_call, input) {
        Ok(tool.complete(input <> "!"))
      }),
      tool.handle_call(object_definition, fn(_call, _input) {
        Ok(tool.complete(3))
      }),
    ])
  let peer = testing.connect(srv, Nil)
  client.call(peer, text_definition, "hi")
  |> should.equal(Ok(client.Succeeded("hi!", [content.text("hi!")])))
  client.call(peer, object_definition, "x")
  |> should.equal(Ok(client.Succeeded(3, [content.text("{\"count\":3}")])))
  client.close(peer)
}

pub fn complete_with_content_replaces_the_text_mirror_test() {
  let definition = tool.define("rich", text_input("in"), codec.string())
  let blocks = [
    content.text("rich"),
    content.image(<<1, 2, 3>>, "image/png"),
  ]
  let peer =
    testing.connect(
      server.new([
        tool.handle_call(definition, fn(_call, input) {
          Ok(tool.complete_with_content(input, blocks))
        }),
      ]),
      Nil,
    )
  client.call(peer, definition, "structured")
  |> should.equal(Ok(client.Succeeded("structured", blocks)))
  client.close(peer)
}

pub fn content_only_tool_does_not_need_output_codec_test() {
  let definition = tool.define_content("content", text_input("input"))
  let bound = tool.handle(definition, fn(input) { Ok([content.text(input)]) })
  tool.tool_declaration(bound).output_schema |> should.equal(None)
  let peer = testing.connect(server.new([bound]), Nil)
  client.call(peer, definition, "hello")
  |> should.equal(
    Ok(client.Succeeded([content.text("hello")], [content.text("hello")])),
  )
  // A discovered call of a content-only tool has no structured value.
  let assert Ok(client.Succeeded(value.Null, [_])) =
    client.call_discovered(
      peer,
      tool.declaration(definition),
      value.Object([#("input", value.String("hello"))]),
    )
  client.close(peer)
}

pub fn content_handler_can_reply_with_only_content_test() {
  let definition = tool.define_content("advanced_content", codec.success(Nil))
  let peer =
    testing.connect(
      server.new([
        tool.handle_call(definition, fn(_call, _input) {
          Ok(tool.complete([content.text("only")]))
        }),
      ]),
      Nil,
    )
  let assert Ok(result) =
    client.call_raw(peer, "tools/call", Some("advanced_content"), [
      #("name", json.string("advanced_content")),
      #("arguments", json.object([])),
    ])
  let assert value.Object(members) = result
  list.key_find(members, "structuredContent") |> should.be_error
  client.call(peer, definition, Nil)
  |> should.equal(
    Ok(client.Succeeded([content.text("only")], [content.text("only")])),
  )
  client.close(peer)
}

pub fn handle_call_composes_input_rounds_and_content_test() {
  let definition = tool.define("advanced", text_input("input"), codec.string())
  let bound =
    tool.handle_call(definition, fn(call, input) {
      case dict.get(tool.input_responses(call), "choice") {
        Error(Nil) ->
          Ok(
            tool.request_input(
              dict.from_list([#("choice", elicitation("Pick one"))]),
            ),
          )
        Ok(answer) ->
          Ok(
            tool.complete_with_content(input <> tool.context(call), [
              content.text("rich " <> value.to_string(answer)),
            ]),
          )
      }
    })
  let peer = connect_with_input(server.new([bound]), " world")
  let assert Ok(client.InputRequired(continuation, requests)) =
    client.call(peer, definition, "hello")
  let assert Ok(tool.InputRequest(tool.Elicitation, value.Object(params))) =
    dict.get(requests, "choice")
  list.key_find(params, "message") |> should.equal(Ok(value.String("Pick one")))
  client.resume(
    continuation,
    dict.from_list([#("choice", json.object([#("pick", json.int(2))]))]),
  )
  |> should.equal(
    Ok(client.Succeeded("hello world", [content.text("rich {\"pick\":2}")])),
  )
  client.close(peer)
}

pub fn request_input_omits_methods_the_client_did_not_declare_test() {
  let definition = tool.define("asks", text_input("input"), codec.string())
  let bound =
    tool.handle_call(definition, fn(_call, _input) {
      Ok(
        tool.request_input(
          dict.from_list([
            #("form", elicitation("Name?")),
            #("roots", tool.InputRequest(tool.Roots, value.Object([]))),
          ]),
        ),
      )
    })
  let peer = connect_with_input(server.new([bound]), Nil)
  let assert Ok(client.InputRequired(_, requests)) =
    client.call(peer, definition, "x")
  dict.keys(requests) |> should.equal(["form"])
  client.close(peer)
  tool.input_method_name(tool.Elicitation) |> should.equal("elicitation/create")
  tool.input_method_name(tool.Sampling)
  |> should.equal("sampling/createMessage")
  tool.input_method_name(tool.Roots) |> should.equal("roots/list")
}

// --- the call, through the reducer -------------------------------------------

type Observed {
  Observed(
    context: String,
    responses: dict.Dict(String, value.Value),
    invocation_id: Int,
    correlation: option.Option(correlation.Correlation),
    client_info: option.Option(tool.ClientInfo),
  )
}

fn tools_call_bytes(name: String, input: String) -> BitArray {
  let meta =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
      #(
        "io.modelcontextprotocol/clientInfo",
        json.object([
          #("name", json.string("probe")),
          #("version", json.string("1.2.3")),
        ]),
      ),
      #("progressToken", json.string("progress-1")),
    ])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(7)),
    #("method", json.string("tools/call")),
    #(
      "params",
      json.object([
        #("_meta", meta),
        #("name", json.string(name)),
        #("arguments", json.object([#("input", json.string(input))])),
      ]),
    ),
  ])
  |> json.to_string
  |> bit_array.from_string
}

pub fn call_accessors_expose_the_invocation_test() {
  let observed = process.new_subject()
  let progress = process.new_subject()
  let definition = tool.define("probe", text_input("input"), codec.string())
  let bound =
    tool.handle_call(definition, fn(call, input) {
      tool.report_progress(call, 3.0, Some(10.0), Some("working"))
      process.send(
        observed,
        Observed(
          context: tool.context(call),
          responses: tool.input_responses(call),
          invocation_id: tool.invocation_id(call),
          correlation: tool.correlation(call),
          client_info: tool.client_info(call),
        ),
      )
      Ok(tool.complete(tool.context(call) <> input))
    })
  let corr = correlation.from_key("tool-test")
  let state = reducer.init(server.new([bound]))
  let exchange = reducer.new_exchange_id()
  let #(state, effects) =
    reducer.step(
      state,
      reducer.Received(
        exchange,
        "prefix:",
        tools_call_bytes("probe", "hello"),
        Some(corr),
      ),
    )
  let assert [reducer.Admitted(_, "tools/call"), reducer.Start(invocation)] =
    effects
  reducer.invocation_tool(invocation) |> should.equal(Some("probe"))
  let finished =
    reducer.perform(invocation, fn(p, total, message) {
      process.send(progress, #(p, total, message))
    })
  let assert Ok(seen) = process.receive(observed, 100)
  seen
  |> should.equal(Observed(
    context: "prefix:",
    responses: dict.new(),
    invocation_id: reducer.invocation_id_to_int(reducer.invocation_id(
      invocation,
    )),
    correlation: Some(corr),
    client_info: Some(tool.ClientInfo("probe", "1.2.3")),
  ))
  process.receive(progress, 100)
  |> should.equal(Ok(#(3.0, Some(10.0), Some("working"))))
  let #(_, effects) = reducer.step(state, finished)
  let assert [reducer.Write(_, bytes), reducer.Close(_)] = effects
  let assert Ok(text) = bit_array.to_string(bytes)
  let assert Ok(structured) =
    json.parse(text, decode.at(["result", "structuredContent"], decode.string))
  structured |> should.equal("prefix:hello")
}

pub fn content_definition_retains_metadata_and_invocation_context_test() {
  let definition =
    tool.define_content("content_context", text_input("input"))
    |> tool.with_description("Context-aware content")
  let bound =
    tool.handle_call(definition, fn(call, input) {
      Ok(tool.complete([content.text(tool.context(call) <> input)]))
    })
  let declaration = tool.tool_declaration(bound)
  declaration.description |> should.equal(Some("Context-aware content"))
  declaration.output_schema |> should.equal(None)
  let peer = testing.connect(server.new([bound]), "prefix:")
  let assert Ok(client.Succeeded(blocks, _)) =
    client.call(peer, definition, "hello")
  blocks |> should.equal([content.text("prefix:hello")])
  client.close(peer)
}

fn must_int(n: Int) -> number.Number {
  let assert Ok(found) = number.from_int(n)
  found
}
