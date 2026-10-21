//// Serve over stdio. A client launches the server as a child process with
//// `client.stdio("my_server", ["--flag"])`. Stdio enforces no authorization:
//// run it under a trusted parent process.
////
//// Compiled by the gate but not run by it, because `serve` reads standard
//// input until the peer closes it. Run: `gleam run -m relay_usage/stdio_server`

// snips-start: stdio-server
import relay/server
import relay/stdio

pub fn main() -> Nil {
  let assert Ok(Nil) = stdio.serve(server.new([]), Nil)
  Nil
}
// snips-end: stdio-server
