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
