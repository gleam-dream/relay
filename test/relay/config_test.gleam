import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value
import relay/client
import relay/completion
import relay/content
import relay/prompts
import relay/resources
import relay/server
import relay/tool
import relay/transport/http

pub fn main() -> Nil {
  gleeunit.main()
}

fn empty_server() -> server.Server(Nil) {
  let assert Ok(registry) = tool.registry([])
  server.server(registry)
}

fn listing_request(method: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(1)),
    #("method", json.string(method)),
    #(
      "params",
      json.object([
        #(
          "_meta",
          json.object([
            #(
              "io.modelcontextprotocol/protocolVersion",
              json.string("2026-07-28"),
            ),
            #("io.modelcontextprotocol/clientCapabilities", json.object([])),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

pub fn service_modifiers_replace_lists_and_preserve_dispatch_test() {
  let assert Ok(name) = tool.tool_name("custom")
  let assert Ok(tool) = case
    tool.definition(
      name,
      codec.field("message", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(message) { Ok(message) },
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
  let assert Ok(registry) = tool.registry([tool])
  let base =
    server.server(registry)
    |> server.with_dispatch(
      fn(current_registry, context, name, args, inputs, progress) {
        case tool.contains(current_registry, name) {
          True ->
            tool.dispatch_with_inputs(
              current_registry,
              context,
              name,
              args,
              inputs,
              progress,
            )
          False ->
            Ok(tool.StructuredWithContent(value.String("custom dispatch"), []))
        }
      },
    )
  let first =
    resources.resource("memory://first", "first", fn(_context, uri) {
      Ok([content.TextResourceContents(uri, "first", None)])
    })
  let second =
    resources.resource("memory://second", "second", fn(_context, uri) {
      Ok([content.TextResourceContents(uri, "second", None)])
    })
  let assert Ok(template) =
    resources.resource_template(
      "memory://second/{id}",
      "second template",
      fn(_context, uri) {
        Ok([content.TextResourceContents(uri, "template", None)])
      },
    )
  let prompt =
    prompts.prompt("p", [], fn(_context, _arguments) {
      Ok(prompts.PromptResult(None, []))
    })
  let completion =
    completion.completion(fn(_context, _reference, argument) {
      Ok(completion.CompletionValues([argument.value], None, None))
    })
  let configured =
    base
    |> server.with_resources([first])
    |> server.with_prompts([prompt])
    |> server.with_resources([second])
    |> server.with_resource_templates([template])
    |> server.with_completion(Some(completion))
    |> server.with_completion(None)
  // Registry and custom dispatch survive modifiers in either order.
  server.registered_tools(configured) |> list.length |> should.equal(1)
  let #(_, resource_effects) =
    server.step(
      configured,
      server.MessageReceived(
        server.fresh_exchange(),
        Nil,
        listing_request("resources/list"),
      ),
    )
  let assert [_, server.Write(_, resource_bytes), _] = resource_effects
  let assert Ok(resource_text) = bit_array.to_string(resource_bytes)
  string.contains(resource_text, "memory://second") |> should.be_true
  string.contains(resource_text, "memory://first") |> should.be_false
  let #(_, prompt_effects) =
    server.step(
      configured,
      server.MessageReceived(
        server.fresh_exchange(),
        Nil,
        listing_request("prompts/list"),
      ),
    )
  let assert [_, server.Write(_, prompt_bytes), _] = prompt_effects
  let assert Ok(prompt_text) = bit_array.to_string(prompt_bytes)
  string.contains(prompt_text, "\"name\":\"p\"") |> should.be_true
  let #(_, template_effects) =
    server.step(
      configured,
      server.MessageReceived(
        server.fresh_exchange(),
        Nil,
        listing_request("resources/templates/list"),
      ),
    )
  let assert [_, server.Write(_, template_bytes), _] = template_effects
  let assert Ok(template_text) = bit_array.to_string(template_bytes)
  string.contains(template_text, "memory://second/{id}") |> should.be_true
  let #(_, discovery_effects) =
    server.step(
      configured,
      server.MessageReceived(
        server.fresh_exchange(),
        Nil,
        listing_request("server/discover"),
      ),
    )
  let assert [_, server.Write(_, discovery_bytes), _] = discovery_effects
  let assert Ok(discovery_text) = bit_array.to_string(discovery_bytes)
  string.contains(discovery_text, "\"completions\"") |> should.be_false
  let envelope =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(1)),
      #("method", json.string("tools/call")),
      #(
        "params",
        json.object([
          #(
            "_meta",
            json.object([
              #(
                "io.modelcontextprotocol/protocolVersion",
                json.string("2026-07-28"),
              ),
              #("io.modelcontextprotocol/clientCapabilities", json.object([])),
            ]),
          ),
          #("name", json.string("custom")),
          #("arguments", json.object([#("message", json.string("hello"))])),
        ]),
      ),
    ])
    |> json.to_string()
    |> bit_array.from_string()
  let #(configured, effects) =
    server.step(
      configured,
      server.MessageReceived(server.fresh_exchange(), Nil, envelope),
    )
  let assert [_, server.StartInvocation(invocation)] = effects
  let #(_, effects) = server.step(configured, server.perform(invocation))
  let assert [server.Write(_, response), _] = effects
  let assert Ok(response) = bit_array.to_string(response)
  string.contains(response, "hello") |> should.be_true

  let #(without_tool, changed) = server.unregister_tool(configured, name)
  changed |> should.be_true
  let #(without_tool, effects) =
    server.step(
      without_tool,
      server.MessageReceived(server.fresh_exchange(), Nil, envelope),
    )
  let assert [_, server.StartInvocation(invocation)] = effects
  let #(_, effects) = server.step(without_tool, server.perform(invocation))
  let assert [server.Write(_, fallback_response), _] = effects
  let assert Ok(fallback_text) = bit_array.to_string(fallback_response)
  string.contains(fallback_text, "custom dispatch") |> should.be_true
}

pub fn url_config_admits_only_supported_components_test() {
  [
    "http://",
    "ftp://localhost/",
    "http://user@localhost/",
    "http://localhost/?q=1",
    "http://localhost/#fragment",
    "http://localhost:0/",
    "http://localhost:65536/",
    "http://localhost:bad/",
    "http://localhost:/",
    "http://local host/",
    "http://[::1/",
    "http://[:::]/",
    "http://[::1]evil/",
    "http://localhost/has space",
    "http://localhost/%GG",
    "http://localhost/%A",
  ]
  |> list.each(fn(url) {
    client.http_config(url)
    |> should.equal(Error(client.InvalidClientConfiguration))
  })
  let assert Ok(_) = client.http_config("http://localhost")
  let assert Ok(_) = client.http_config("HTTP://localhost/")
  let assert Ok(_) = client.http_config("http://localhost:080/%61")
  let assert Ok(_) = client.http_config("https://[::1]:443/%61")
}

pub fn configured_http_lifecycle_test() {
  let listener =
    http.listener(empty_server(), fn() { Nil })
    |> http.with_options(http.HttpOptions(port: 0, host: "127.0.0.1"))
  let assert Ok(running) = http.start(listener)
  let url = "http://127.0.0.1:" <> int.to_string(http.http_server_port(running))
  let assert Ok(config) = client.http_config(url)
  let config =
    config
    |> client.with_timeout(1000)
    |> client.with_timeout(3000)
    |> client.with_max_response_bytes(65_536)
  let assert Ok(peer) = client.connect_http(config)
  let assert Ok(discovery) = client.discover(peer)
  discovery.supported_versions
  |> list.contains("2026-07-28")
  |> should.be_true
  client.close(peer)
  client.connect_http(client.with_ca_cert_file(config, "ca.pem"))
  |> should.equal(Error(client.InvalidClientConfiguration))
  client.connect_http(client.with_timeout(config, 0))
  |> should.equal(Error(client.InvalidClientConfiguration))
  http.stop_http_server(running)
}

pub fn stdio_config_starts_bounded_and_allows_named_updates_test() {
  let config = client.stdio_config("/bin/echo", ["ready"])
  config.executable |> should.equal("/bin/echo")
  config.args |> should.equal(["ready"])
  config.timeout_ms |> should.equal(30_000)
  config.max_response_bytes |> should.equal(1_048_576)
  let adjusted = client.StdioConfig(..config, timeout_ms: 500)
  adjusted.timeout_ms |> should.equal(500)
  adjusted.max_response_bytes |> should.equal(1_048_576)
}

pub fn configured_https_lifecycle_and_invalid_listener_test() {
  let base = http.listener(empty_server(), fn() { Nil })
  http.start(http.with_options(base, http.HttpOptions(port: -1, host: "")))
  |> should.equal(Error(
    "Invalid Relay HTTP listener options, policy, or TLS settings",
  ))
  http.start(http.with_tls(base, "", "key"))
  |> should.equal(Error(
    "Invalid Relay HTTP listener options, policy, or TLS settings",
  ))
  http.start(http.with_tls(base, "missing.crt", "missing.key"))
  |> should.equal(Error(
    "Invalid Relay HTTP listener options, policy, or TLS settings",
  ))
  http.start(http.with_options(
    base,
    http.HttpOptions(port: 0, host: "bad host"),
  ))
  |> should.equal(Error(
    "Invalid Relay HTTP listener options, policy, or TLS settings",
  ))
  let assert Ok(running) =
    base
    |> http.with_tls(
      "test/fixtures/tls/localhost.crt",
      "test/fixtures/tls/localhost.key",
    )
    |> http.start()
  let url =
    "https://localhost:" <> int.to_string(http.http_server_port(running)) <> "/"
  let assert Ok(config) = client.http_config(url)
  let config = client.with_ca_cert_file(config, "test/fixtures/tls/root-ca.crt")
  let assert Ok(peer) = client.connect_http(config)
  let assert Ok(_) = client.discover(peer)
  client.close(peer)
  http.stop_http_server(running)
}
