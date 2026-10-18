# Relay usage examples

Runnable, compiled recipes for the public Relay API. The package depends on
Relay by path, so a change that breaks a recipe fails the examples gate.

| Module           | Shows                                                           | Run                                       |
| ---------------- | --------------------------------------------------------------- | ----------------------------------------- |
| `serve_and_call` | Serve a tool over HTTP, call it, and handle failed calls        | `gleam run -m relay_usage/serve_and_call` |
| `stdio_server`   | Serve over stdio (compiled only: it reads standard input)       | `gleam run -m relay_usage/stdio_server`   |
| `mount`          | Mount the endpoint in an application with a per-request context | `gleam run -m relay_usage/mount`          |
| `protect`        | Bearer verification, challenges and an introspecting verifier   | `gleam run -m relay_usage/protect`        |
| `call_controls`  | Deadline, cancellation, headers and the request deadline        | `gleam run -m relay_usage/call_controls`  |
| `correlation`    | Correlation, idempotency key, request and invocation ids        | `gleam run -m relay_usage/correlation`    |
| `typed_output`   | Fold a call result into one typed `Result`                      | `gleam run -m relay_usage/typed_output`   |

Run them all with `gleam test` from this directory inside `nix develop`. The
gate runs the same tests through `python3 -B scripts/check.py fast`.
