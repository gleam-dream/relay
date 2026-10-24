//// The description of an MCP server: its tools, resources, prompts,
//// completion handler, tool access policy and identity.
////
//// `new(tools)` builds a `Server` from bound tools (`relay/tool`); it panics
//// on a repeated tool name, because tool lists are written in source code.
//// The `with_*` setters add services and replace earlier values.
//// `register_tool` and `unregister_tool` change a description, for example
//// before it is served; a running server changes through
//// `relay/http.register_tool` or `relay/runtime.register_tool`. A `Server` is
//// an immutable value and holds no connection state: serve it with
//// `relay/http`, `relay/stdio` or `relay/runtime`. It holds one random key,
//// made by `new`, that signs its pagination cursors and input-round state,
//// so a token from one HTTP request stays valid on the next.
////
//// ```gleam
//// import json/blueprint/codec
//// import relay/content
//// import relay/resources
//// import relay/server
//// import relay/tool
////
//// pub fn service() -> server.Server(Nil) {
////   let say_input = {
////     use text <- codec.field("text", codec.string(), get: fn(text) { text })
////     codec.success(text)
////   }
////   let say =
////     tool.define("say", say_input, codec.string())
////     |> tool.handle(fn(text) { Ok(text) })
////   let readme =
////     resources.static("memo://readme", "Readme", fn(_context, uri) {
////       Ok([content.text_resource(uri, "Hello")])
////     })
////   server.new([say])
////   |> server.with_resources([readme])
////   |> server.with_info("notes", "1.0.0")
//// }
//// ```

import gleam/list
import gleam/option.{None, Some}
import relay/internal/core
import relay/tool.{type Declaration, type Tool}

/// An MCP server description.
pub type Server(context) =
  core.Server(context)

/// Why `register_tool` refused a tool.
pub type RegisterError {
  DuplicateTool(name: String)
}

/// A one-line description of a registration error.
pub fn describe_register_error(error: RegisterError) -> String {
  case error {
    DuplicateTool(name) ->
      "a tool named \"" <> name <> "\" is already registered"
  }
}

@external(erlang, "relay_ffi", "new_cursor_key")
fn new_cursor_key() -> BitArray

/// A server with these tools and no other services. Panics when two tools
/// share a name; register tools built from runtime data one by one with
/// `register_tool` instead.
pub fn new(tools: List(Tool(context))) -> Server(context) {
  let empty =
    core.Server(
      tools: [],
      resources: [],
      prompts: [],
      completion: None,
      visible: fn(_, _) { True },
      callable: fn(_, _) { True },
      name: "relay",
      version: "0.1.0",
      instructions: None,
      cursor_key: new_cursor_key(),
    )
  list.fold(tools, empty, fn(server, tool) {
    case register_tool(server, tool) {
      Ok(server) -> server
      Error(error) ->
        panic as { "relay/server.new: " <> describe_register_error(error) }
    }
  })
}

/// Replaces the static resources and resource templates.
pub fn with_resources(
  server: Server(context),
  resources: List(core.Resource(context)),
) -> Server(context) {
  core.Server(..server, resources: resources)
}

/// Replaces the prompts.
pub fn with_prompts(
  server: Server(context),
  prompts: List(core.Prompt(context)),
) -> Server(context) {
  core.Server(..server, prompts: prompts)
}

/// Sets the completion handler for prompt and resource-template arguments.
pub fn with_completion(
  server: Server(context),
  completion: core.Completion(context),
) -> Server(context) {
  core.Server(..server, completion: Some(completion))
}

/// Decides per request which tools a client sees and may call. `visible`
/// filters `tools/list`; a call needs both `visible` and `callable`. A
/// hidden, denied and unknown tool all produce the same error, so a client
/// cannot tell them apart. Both default to allowing every tool. Decide
/// argument-dependent permissions inside the handler.
pub fn with_tool_access(
  server: Server(context),
  visible visible: fn(context, Declaration) -> Bool,
  callable callable: fn(context, Declaration) -> Bool,
) -> Server(context) {
  core.Server(
    ..server,
    visible: fn(context, entry) {
      visible(context, tool.tool_declaration(entry))
    },
    callable: fn(context, entry) {
      callable(context, tool.tool_declaration(entry))
    },
  )
}

/// Sets the name and version that `server/discover` reports; the default
/// is `relay` `0.1.0`.
pub fn with_info(
  server: Server(context),
  name: String,
  version: String,
) -> Server(context) {
  core.Server(..server, name: name, version: version)
}

/// Sets the instructions `server/discover` gives clients about using this
/// server.
pub fn with_instructions(
  server: Server(context),
  instructions: String,
) -> Server(context) {
  core.Server(..server, instructions: Some(instructions))
}

/// Adds a tool, or fails when its name is taken.
pub fn register_tool(
  server: Server(context),
  tool: Tool(context),
) -> Result(Server(context), RegisterError) {
  case has_tool(server, tool.info.name) {
    True -> Error(DuplicateTool(tool.info.name))
    False -> Ok(core.Server(..server, tools: list.append(server.tools, [tool])))
  }
}

/// Removes the tool with this name, if there is one.
pub fn unregister_tool(
  server: Server(context),
  name: String,
) -> Server(context) {
  core.Server(
    ..server,
    tools: list.filter(server.tools, fn(tool) { tool.info.name != name }),
  )
}

/// Whether a tool with this name is registered.
pub fn has_tool(server: Server(context), name: String) -> Bool {
  list.any(server.tools, fn(tool) { tool.info.name == name })
}

/// The declarations of every registered tool, in registration order and
/// without the access policy applied.
pub fn tools(server: Server(context)) -> List(Declaration) {
  list.map(server.tools, tool.tool_declaration)
}
