import gleam/erlang/process
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import json/blueprint/codec
import json/blueprint/number
import json/blueprint/value
import relay
import relay/tool

pub fn main() -> Nil {
  gleeunit.main()
}

// Positive test: Two tools with unrelated native input, output, and application-error
// types coexist in one registry and are listed and invoked through the same public server.
pub fn heterogeneous_tools_registry_test() {
  let assert Ok(echo_name) = relay.tool_name("echo")
  let assert Ok(math_name) = relay.tool_name("add")

  // Tool 1: string -> string, error is Nil
  let assert Ok(echo_tool) =
    relay.context_tool(
      echo_name,
      relay.tool_metadata("Echoes input text"),
      codec.field("message", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: String, msg: String) { Ok("echo: " <> msg) },
    )

  // Tool 2: Int -> Int, error is String
  let assert Ok(math_tool) =
    relay.context_tool(
      math_name,
      relay.tool_metadata("Adds 1 to integer"),
      codec.field("amount", codec.int()),
      codec.int(),
      codec.string(),
      fn(_ctx: String, n: Int) { Ok(n + 1) },
    )

  let assert Ok(reg) = relay.registry([echo_tool, math_tool])

  let decls = relay.declarations(reg, "test-context")
  decls |> should.not_equal([])

  // Verify dispatch tool 1
  let echo_args = value.Object([#("message", value.String("hello"))])
  let assert Ok(echo_res) =
    relay.dispatch(reg, "test-context", echo_name, echo_args)
  echo_res |> should.equal(value.String("echo: hello"))

  // Verify dispatch tool 2
  let assert Ok(math_arg_num) = number.from_int(41)
  let math_args = value.Object([#("amount", value.Number(math_arg_num))])
  let assert Ok(math_res) =
    relay.dispatch(reg, "test-context", math_name, math_args)
  let assert Ok(expected_num) = number.from_int(42)
  math_res |> should.equal(value.Number(expected_num))
}

// Negative test: duplicate tool names rejected
pub fn duplicate_tool_name_rejected_test() {
  let assert Ok(name) = relay.tool_name("duplicate")
  let assert Ok(tool1) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("a", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: Nil, msg: String) { Ok(msg) },
    )
  let assert Ok(tool2) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("b", codec.int()),
      codec.int(),
      codec.object(codec.empty()),
      fn(_ctx: Nil, n: Int) { Ok(n) },
    )

  let result = relay.registry([tool1, tool2])
  case result {
    Error(tool.DuplicateToolName(dup)) -> dup |> should.equal(name)
    _ -> should.fail()
  }
}

// Negative test: invalid tool name (empty or whitespace or control characters)
pub fn invalid_tool_name_test() {
  relay.tool_name("") |> should.be_error()
  relay.tool_name("tool name with spaces") |> should.be_error()
  relay.tool_name("bad\nnewline") |> should.be_error()
  relay.tool_name("bad\u{0000}null") |> should.be_error()
}

// Negative test: primitive root input schema rejected
pub fn primitive_root_input_schema_rejected_test() {
  let assert Ok(name) = relay.tool_name("primitive_input")
  // Using codec.int() directly as input schema has no object root
  let result =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.int(),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: Nil, _n: Int) { Ok("ok") },
    )
  case result {
    Error(tool.InputSchemaMustBeObject(_)) -> Nil
    _ -> should.fail()
  }
}

// Negative test: unknown tool dispatch
pub fn unknown_tool_dispatch_test() {
  let assert Ok(reg) = relay.registry([])
  let assert Ok(ghost) = relay.tool_name("ghost")
  let result = relay.dispatch(reg, Nil, ghost, value.Object([]))
  case result {
    Error(tool.UnknownTool(name)) -> name |> should.equal(ghost)
    _ -> should.fail()
  }
}

// Negative test: invalid input arguments
pub fn invalid_input_arguments_test() {
  let assert Ok(name) = relay.tool_name("strict_input")
  let assert Ok(t) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("msg", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: Nil, msg: String) { Ok(msg) },
    )
  let assert Ok(reg) = relay.registry([t])
  // Passing wrong type: int instead of string
  let assert Ok(num) = number.from_int(99)
  let bad_args = value.Object([#("msg", value.Number(num))])
  let result = relay.dispatch(reg, Nil, name, bad_args)
  case result {
    Error(tool.InvalidInput(_)) -> Nil
    _ -> should.fail()
  }
}

// Negative test: application failure encoded as ApplicationFailure(Value)
pub fn application_failure_dispatch_test() {
  let assert Ok(name) = relay.tool_name("app_fail")
  let assert Ok(t) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("in", codec.string()),
      codec.string(),
      codec.field("err_code", codec.int()),
      fn(_ctx: Nil, _in: String) { Error(404) },
    )
  let assert Ok(reg) = relay.registry([t])
  let args = value.Object([#("in", value.String("x"))])
  let result = relay.dispatch(reg, Nil, name, args)

  case result {
    Error(tool.ApplicationFailure(val)) -> {
      let assert Ok(expected_num) = number.from_int(404)
      val
      |> should.equal(value.Object([#("err_code", value.Number(expected_num))]))
    }
    _ -> should.fail()
  }
}

// Regression test F2: Exact Blueprint numbers preserved through tool dispatch
pub fn exact_blueprint_number_preservation_test() {
  let assert Ok(name) = relay.tool_name("exact_num")
  let assert Ok(t) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("num", codec.number()),
      codec.number(),
      codec.object(codec.empty()),
      fn(_ctx: Nil, n: number.Number) { Ok(n) },
    )
  let assert Ok(reg) = relay.registry([t])

  // A 50-digit number that would lose precision in standard IEEE 754 Float
  let num_str = "12345678901234567890123456789012345678901234567890"
  let assert Ok(limits) = number.number_limits(1024, 100, 1000)
  let assert Ok(parsed_num) = number.parse_number(limits, num_str)

  let args = value.Object([#("num", value.Number(parsed_num))])
  let assert Ok(res) = relay.dispatch(reg, Nil, name, args)

  res |> should.equal(value.Number(parsed_num))
}

// Regression test F4: Tool with missing schema is rejected on admission
pub fn missing_output_schema_admission_rejection_test() {
  let assert Ok(name) = relay.tool_name("bad_schema_tool")
  let calls = process.new_subject()
  let broken_codec =
    codec.new(fn(_x: String) { Ok(value.String("ok")) }, fn(_v: value.Value) {
      Ok("ok")
    })

  let res =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("in", codec.string()),
      broken_codec,
      codec.object(codec.empty()),
      fn(_ctx: Nil, msg: String) {
        process.send(calls, Nil)
        Ok(msg)
      },
    )

  case res {
    Error(tool.MissingOutputSchema) -> Nil
    _ -> should.fail()
  }

  process.receive(calls, 0) |> should.be_error()
}

pub fn primitive_output_schema_is_a_valid_json_schema_test() {
  let assert Ok(name) = relay.tool_name("primitive_output_tool")
  let assert Ok(registered) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("input", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: Nil, input: String) { Ok(input) },
    )
  let assert Ok(registry) = relay.registry([registered])

  case tool.declarations(registry, Nil) {
    [declaration] ->
      declaration.output_schema
      |> should.equal(Some(codec.StringSchema))
    _ -> should.fail()
  }
}

// Regression test: Invalid output from handler produces InvalidOutput error
pub fn invalid_output_encoding_test() {
  let assert Ok(name) = relay.tool_name("range_tool")
  let assert Ok(range_codec) = codec.integer_between(0, 10)
  let assert Ok(t) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("dummy", codec.string()),
      range_codec,
      codec.object(codec.empty()),
      fn(_ctx: Nil, _d: String) {
        // Return 999 which violates range 0..10
        Ok(999)
      },
    )
  let assert Ok(reg) = relay.registry([t])
  let args = value.Object([#("dummy", value.String("hi"))])
  let res = relay.dispatch(reg, Nil, name, args)

  case res {
    Error(tool.InvalidOutput(_)) -> Nil
    _ -> should.fail()
  }
}

// Regression test: Invalid application error encoding produces ErrorEncodingFailure
pub fn error_encoding_failure_test() {
  let assert Ok(name) = relay.tool_name("range_err_tool")
  let assert Ok(range_codec) = codec.integer_between(0, 10)
  let assert Ok(t) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("dummy", codec.string()),
      codec.string(),
      range_codec,
      fn(_ctx: Nil, _d: String) {
        // Return error 999 which violates range 0..10
        Error(999)
      },
    )
  let assert Ok(reg) = relay.registry([t])
  let args = value.Object([#("dummy", value.String("hi"))])
  let res = relay.dispatch(reg, Nil, name, args)

  case res {
    Error(tool.ErrorEncodingFailure(_)) -> Nil
    _ -> should.fail()
  }
}
