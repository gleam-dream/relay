import json/blueprint/codec
import relay
import relay/server
import relay/transport/stdio

pub fn main() -> Nil {
  let assert Ok(greet_name) = relay.tool_name("greet")
  let assert Ok(greet_tool) =
    relay.context_tool(
      greet_name,
      relay.tool_metadata("Greets user"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(ctx: String, user: String) { Ok(ctx <> ": hello " <> user) },
    )

  let assert Ok(fail_name) = relay.tool_name("fail_tool")
  let assert Ok(fail_tool) =
    relay.context_tool(
      fail_name,
      relay.tool_metadata("Fails with tool error"),
      codec.field("msg", codec.string()),
      codec.string(),
      codec.field("reason", codec.string()),
      fn(_ctx: String, msg: String) { Error("application error: " <> msg) },
    )

  let assert Ok(reg) = relay.registry([greet_tool, fail_tool])
  let s = server.server(reg)
  let config = stdio.default_stdio_config()

  // Diagnostic written to isolated stderr
  stdio.log_stderr("Child stdio server starting")

  let _ = stdio.run_local_unprotected_stdio_server(s, config, "child-server")
  Nil
}
