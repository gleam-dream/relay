import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import json/blueprint/number
import json/blueprint/value
import relay/content
import relay/tool

pub fn main() -> Nil {
  gleeunit.main()
}

// Positive test: Two tools with unrelated native input, output, and application-error
// types coexist in one registry and are listed and invoked through the same public server.
pub fn heterogeneous_tools_registry_test() {
  let assert Ok(echo_name) = tool.tool_name("echo")
  let assert Ok(math_name) = tool.tool_name("add")

  // Tool 1: string -> string, error is Nil
  let assert Ok(echo_tool) = case
    tool.definition(
      echo_name,
      codec.field("message", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Echoes input text"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(msg: String) { Ok("echo: " <> msg) },
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

  // Tool 2: Int -> Int, error is String
  let assert Ok(math_tool) = case
    tool.definition(math_name, codec.field("amount", codec.int()), codec.int())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Adds 1 to integer"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(n: Int) { Ok(n + 1) },
          fn(application_error) {
            case codec.encode_json(codec.string(), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }

  let assert Ok(reg) = tool.registry([echo_tool, math_tool])

  let decls = tool.declarations(reg, "test-context")
  decls |> should.not_equal([])

  // Verify dispatch tool 1
  let echo_args = value.Object([#("message", value.String("hello"))])
  let assert Ok(echo_res) =
    tool.dispatch(reg, "test-context", echo_name, echo_args)
  echo_res |> should.equal(value.String("echo: hello"))

  // Verify dispatch tool 2
  let assert Ok(math_arg_num) = number.from_int(41)
  let math_args = value.Object([#("amount", value.Number(math_arg_num))])
  let assert Ok(math_res) =
    tool.dispatch(reg, "test-context", math_name, math_args)
  let assert Ok(expected_num) = number.from_int(42)
  math_res |> should.equal(value.Number(expected_num))
}

// Negative test: duplicate tool names rejected
pub fn duplicate_tool_name_rejected_test() {
  let assert Ok(name) = tool.tool_name("duplicate")
  let assert Ok(tool1) = case
    tool.definition(name, codec.field("a", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(msg: String) { Ok(msg) },
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
  let assert Ok(tool2) = case
    tool.definition(name, codec.field("b", codec.int()), codec.int())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(n: Int) { Ok(n) },
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

  let result = tool.registry([tool1, tool2])
  case result {
    Error(tool.DuplicateToolName(dup)) -> dup |> should.equal(name)
    _ -> should.fail()
  }
}

// Negative test: invalid tool name (empty or whitespace or control characters)
pub fn invalid_tool_name_test() {
  tool.tool_name("") |> should.be_error()
  tool.tool_name("tool name with spaces") |> should.be_error()
  tool.tool_name("bad\nnewline") |> should.be_error()
  tool.tool_name("bad\u{0000}null") |> should.be_error()
}

// Negative test: primitive root input schema rejected
pub fn primitive_root_input_schema_rejected_test() {
  let assert Ok(name) = tool.tool_name("primitive_input")
  // Using codec.int() directly as input schema has no object root
  let result = case tool.definition(name, codec.int(), codec.string()) {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_n: Int) { Ok("ok") },
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
  case result {
    Error(tool.InputSchemaMustBeObject(_)) -> Nil
    _ -> should.fail()
  }
}

// Negative test: unknown tool dispatch
pub fn unknown_tool_dispatch_test() {
  let assert Ok(reg) = tool.registry([])
  let assert Ok(ghost) = tool.tool_name("ghost")
  let result = tool.dispatch(reg, Nil, ghost, value.Object([]))
  case result {
    Error(tool.UnknownTool(name)) -> name |> should.equal(ghost)
    _ -> should.fail()
  }
}

// Negative test: invalid input arguments
pub fn invalid_input_arguments_test() {
  let assert Ok(name) = tool.tool_name("strict_input")
  let assert Ok(t) = case
    tool.definition(name, codec.field("msg", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(msg: String) { Ok(msg) },
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
  // Passing wrong type: int instead of string
  let assert Ok(num) = number.from_int(99)
  let bad_args = value.Object([#("msg", value.Number(num))])
  let result = tool.dispatch(reg, Nil, name, bad_args)
  case result {
    Error(tool.InvalidInput(_)) -> Nil
    _ -> should.fail()
  }
}

// An explicit renderer can retain the deliberate JSON error text.
pub fn application_failure_dispatch_test() {
  let assert Ok(name) = tool.tool_name("app_fail")
  let assert Ok(t) = case
    tool.definition(name, codec.field("in", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_in: String) { Error(404) },
          fn(application_error) {
            case
              codec.encode_json(
                codec.field("err_code", codec.int()),
                application_error,
              )
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
  let args = value.Object([#("in", value.String("x"))])
  let result = tool.dispatch(reg, Nil, name, args)

  case result {
    Error(tool.PublicApplicationFailure(text)) ->
      text |> should.equal("{\"err_code\":404}")
    _ -> should.fail()
  }
}

// Regression test F2: Exact Blueprint numbers preserved through tool dispatch
pub fn exact_blueprint_number_preservation_test() {
  let assert Ok(name) = tool.tool_name("exact_num")
  let assert Ok(t) = case
    tool.definition(name, codec.field("num", codec.number()), codec.number())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(n: number.Number) { Ok(n) },
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

  // A 50-digit number that would lose precision in standard IEEE 754 Float
  let num_str = "12345678901234567890123456789012345678901234567890"
  let assert Ok(limits) = number.number_limits(1024, 100, 1000)
  let assert Ok(parsed_num) = number.parse_number(limits, num_str)

  let args = value.Object([#("num", value.Number(parsed_num))])
  let assert Ok(res) = tool.dispatch(reg, Nil, name, args)

  res |> should.equal(value.Number(parsed_num))
}

// Regression test F4: Tool with missing schema is rejected on admission
pub fn missing_output_schema_admission_rejection_test() {
  let assert Ok(name) = tool.tool_name("bad_schema_tool")
  let calls = process.new_subject()
  let broken_codec =
    codec.new(fn(_x: String) { Ok(value.String("ok")) }, fn(_v: value.Value) {
      Ok("ok")
    })

  let res = case
    tool.definition(name, codec.field("in", codec.string()), broken_codec)
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(msg: String) {
            process.send(calls, Nil)
            Ok(msg)
          },
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

  case res {
    Error(tool.MissingOutputSchema) -> Nil
    _ -> should.fail()
  }

  process.receive(calls, 0) |> should.be_error()
}

pub fn primitive_output_schema_is_a_valid_json_schema_test() {
  let assert Ok(name) = tool.tool_name("primitive_output_tool")
  let assert Ok(registered) = case
    tool.definition(name, codec.field("input", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(input: String) { Ok(input) },
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
  let assert Ok(registry) = tool.registry([registered])

  case tool.declarations(registry, Nil) {
    [declaration] ->
      declaration.output_schema
      |> should.equal(Some(codec.StringSchema))
    _ -> should.fail()
  }
}

// Regression test: Invalid output from handler produces InvalidOutput error
pub fn invalid_output_encoding_test() {
  let assert Ok(name) = tool.tool_name("range_tool")
  let assert Ok(range_codec) = codec.integer_between(0, 10)
  let assert Ok(t) = case
    tool.definition(name, codec.field("dummy", codec.string()), range_codec)
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(tool.handle_with_error_renderer(
        definition,
        fn(_d: String) {
          // Return 999 which violates range 0..10
          Ok(999)
        },
        fn(application_error) {
          case
            codec.encode_json(codec.object(codec.empty()), application_error)
          {
            Ok(text) -> text
            Error(_) -> "Tool execution failed."
          }
        },
      ))
    }
    Error(error) -> Error(error)
  }
  let assert Ok(reg) = tool.registry([t])
  let args = value.Object([#("dummy", value.String("hi"))])
  let res = tool.dispatch(reg, Nil, name, args)

  case res {
    Error(tool.InvalidOutput(_)) -> Nil
    _ -> should.fail()
  }
}

// A caller-owned renderer can choose a safe fallback when its encoding fails.
pub fn error_encoding_failure_test() {
  let assert Ok(name) = tool.tool_name("range_err_tool")
  let assert Ok(range_codec) = codec.integer_between(0, 10)
  let assert Ok(t) = case
    tool.definition(name, codec.field("dummy", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(tool.handle_with_error_renderer(
        definition,
        fn(_d: String) {
          // Return error 999 which violates range 0..10
          Error(999)
        },
        fn(application_error) {
          case codec.encode_json(range_codec, application_error) {
            Ok(text) -> text
            Error(_) -> "Tool execution failed."
          }
        },
      ))
    }
    Error(error) -> Error(error)
  }
  let assert Ok(reg) = tool.registry([t])
  let args = value.Object([#("dummy", value.String("hi"))])
  let res = tool.dispatch(reg, Nil, name, args)

  case res {
    Error(tool.PublicApplicationFailure("Tool execution failed.")) -> Nil
    _ -> should.fail()
  }
}

pub fn definition_metadata_and_annotation_modifiers_are_independent_test() {
  let assert Ok(name) = tool.tool_name("declared")
  let assert Ok(definition) =
    tool.definition(name, codec.field("input", codec.string()), codec.string())
  let annotations =
    tool.empty_annotations()
    |> tool.with_read_only_hint(Some(True))
    |> tool.with_open_world_hint(Some(True))
    |> tool.with_destructive_hint(Some(False))
  let definition =
    definition
    |> tool.with_description("Looks up a record")
    |> tool.with_title("Lookup")
    |> tool.with_annotations(annotations)
    |> tool.with_required_client_capabilities(["sampling"])
  should.equal(tool.definition_name(definition), name)
  should.equal(
    tool.definition_metadata(definition),
    tool.ToolMetadata(
      description: Some("Looks up a record"),
      title: Some("Lookup"),
      annotations: Some(annotations),
      required_client_capabilities: ["sampling"],
    ),
  )
  let assert Ok(encoded) =
    codec.encode(tool.definition_input_codec(definition), "x")
  should.equal(encoded, value.Object([#("input", value.String("x"))]))
  let assert Ok(registered) =
    tool.registry([
      tool.handle(definition, fn(input) { Ok(input) }),
    ])
  let assert [declaration] = tool.declarations(registered, Nil)
  should.equal(declaration.metadata, tool.definition_metadata(definition))
  should.equal(annotations.read_only_hint, Some(True))
  should.equal(annotations.open_world_hint, Some(True))
  should.equal(annotations.destructive_hint, Some(False))
  should.equal(annotations.idempotent_hint, None)
  let annotation_json =
    json.to_string(tool.tool_annotations_to_json(annotations))
  should.be_true(string.contains(annotation_json, "\"readOnlyHint\":true"))
  should.be_true(string.contains(annotation_json, "\"openWorldHint\":true"))
  should.be_true(string.contains(annotation_json, "\"destructiveHint\":false"))
  should.be_false(string.contains(annotation_json, "idempotentHint"))
}

pub fn definition_admission_and_generic_error_test() {
  let assert Ok(name) = tool.tool_name("plain_error")
  let input = codec.field("input", codec.string())
  let broken =
    codec.new(fn(_x: String) { Ok(value.String("ok")) }, fn(_v: value.Value) {
      Ok("ok")
    })
  should.equal(
    tool.definition(name, codec.string(), codec.string()),
    Error(tool.InputSchemaMustBeObject("string")),
  )
  should.equal(
    tool.definition(name, input, broken),
    Error(tool.MissingOutputSchema),
  )
  let assert Ok(definition) = tool.definition(name, input, codec.string())
  let assert Ok(registry) =
    tool.registry([
      tool.handle(definition, fn(_input) { Error("secret detail") }),
    ])
  let outcome =
    tool.dispatch(
      registry,
      Nil,
      name,
      value.Object([#("input", value.String("x"))]),
    )
  should.equal(
    outcome,
    Error(tool.PublicApplicationFailure("Tool execution failed.")),
  )
}

pub fn content_only_tool_does_not_need_output_codec_test() {
  let assert Ok(name) = tool.tool_name("content")
  let assert Ok(definition) =
    tool.content_definition(name, codec.field("input", codec.string()))
  let bound =
    tool.handle_content(definition, fn(input) {
      Ok([content.text_content(input)])
    })
  let assert Ok(registry) = tool.registry([bound])
  let assert [declaration] = tool.declarations(registry, Nil)
  should.equal(declaration.output_schema, None)
  should.equal(
    tool.dispatch_with_content(
      registry,
      Nil,
      name,
      value.Object([#("input", value.String("hello"))]),
    ),
    Ok(tool.ContentOnly([content.text_content("hello")])),
  )
}

pub fn advanced_handler_composes_progress_content_and_input_test() {
  let assert Ok(name) = tool.tool_name("advanced")
  let assert Ok(definition) =
    tool.definition(name, codec.field("input", codec.string()), codec.string())
  let seen = process.new_subject()
  let bound =
    tool.handle_advanced(definition, fn(call, input) {
      call.report_progress(3)
      case call.input_responses {
        None ->
          Ok(
            tool.NeedsInput(
              dict.from_list([
                #(
                  "choice",
                  tool.InputRequest("elicitation/create", json.object([])),
                ),
              ]),
            ),
          )
        Some(_) ->
          Ok(
            tool.Complete(input <> call.application, [
              content.text_content("rich"),
            ]),
          )
      }
    })
  let assert Ok(registry) = tool.registry([bound])
  let arguments = value.Object([#("input", value.String("hello"))])
  let progress = fn(n) { process.send(seen, n) }
  let assert Ok(tool.InputRequired(requests)) =
    tool.dispatch_with_inputs(
      registry,
      " world",
      name,
      arguments,
      None,
      progress,
    )
  dict.has_key(requests, "choice") |> should.be_true()
  let assert Ok(3) = process.receive(seen, 100)
  let assert Ok(tool.StructuredWithContent(output, blocks)) =
    tool.dispatch_with_inputs(
      registry,
      " world",
      name,
      arguments,
      Some(value.Object([])),
      progress,
    )
  output |> should.equal(value.String("hello world"))
  blocks |> should.equal([content.text_content("rich")])
}

pub fn advanced_handler_can_return_content_without_structured_value_test() {
  let assert Ok(name) = tool.tool_name("advanced_content")
  let assert Ok(definition) =
    tool.definition(name, codec.object(codec.empty()), codec.string())
  let bound =
    tool.handle_advanced(definition, fn(_call, _input) {
      Ok(tool.Content([content.text_content("only")]))
    })
  let assert Ok(registry) = tool.registry([bound])
  should.equal(
    tool.dispatch_with_content(registry, Nil, name, value.Object([])),
    Ok(tool.ContentOnly([content.text_content("only")])),
  )
}

pub fn content_definition_retains_metadata_and_invocation_context_test() {
  let assert Ok(name) = tool.tool_name("content_context")
  let assert Ok(definition) =
    tool.content_definition(name, codec.field("input", codec.string()))
  let metadata =
    tool.ToolMetadata(
      ..tool.empty_metadata(),
      description: Some("Context-aware content"),
    )
  let definition = tool.content_with_metadata(definition, metadata)
  let reported = process.new_subject()
  let bound =
    tool.handle_content_advanced(definition, fn(call, input) {
      call.report_progress(9)
      Ok([content.text_content(call.application <> input)])
    })
  let assert Ok(registry) = tool.registry([bound])
  let assert [declaration] = tool.declarations(registry, "prefix:")
  declaration.metadata.description
  |> should.equal(Some("Context-aware content"))
  declaration.output_schema |> should.equal(None)
  let assert Ok(tool.ContentOnly(blocks)) =
    tool.dispatch_with_progress(
      registry,
      "prefix:",
      name,
      value.Object([#("input", value.String("hello"))]),
      fn(n) { process.send(reported, n) },
    )
  blocks |> should.equal([content.text_content("prefix:hello")])
  let assert Ok(9) = process.receive(reported, 100)
}

pub fn schema_override_changes_discovery_but_codec_still_validates_test() {
  let assert Ok(name) = tool.tool_name("overridden")
  let assert Ok(definition) =
    tool.definition(name, codec.field("input", codec.string()), codec.string())
  let override =
    value.Object([
      #("type", value.String("object")),
      #("x-mcp-header", value.String("X-Trace")),
    ])
  let assert Ok(definition) =
    tool.with_input_schema_override(definition, override)
  let assert Ok(registry) =
    tool.registry([tool.handle(definition, fn(input) { Ok(input) })])
  tool.input_schema_document(registry, name) |> should.equal(Some(override))
  tool.dispatch(registry, Nil, name, value.Object([]))
  |> should.be_error()
  tool.with_input_schema_override(definition, value.String("bad"))
  |> should.equal(Error(tool.InputSchemaMustBeObject("non-object")))
}
