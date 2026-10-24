import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value
import relay/client
import relay/client/output
import relay/content
import relay/server
import relay/testing
import relay/tool

pub fn require_retains_native_output_test() {
  output.require(Ok(client.Succeeded(#(42, True), [])))
  |> should.equal(Ok(#(42, True)))
}

pub fn transport_evidence_and_original_error_are_preserved_test() {
  let lost = testing.error(client.TimedOut(client.MaybeSent))
  let assert Error(error) = output.require(Error(lost))
  error |> should.equal(output.CallFailed(lost))
  output.error_kind(error) |> should.equal(output.TransportFailure)
  output.evidence(error) |> should.equal(client.MaybeSent)
}

pub fn refusal_is_a_completed_exchange_with_structured_evidence_test() {
  let structured = Some(value.Object([#("reason", value.String("empty"))]))
  let assert Error(error) =
    output.require(Ok(client.ToolFailed([content.text("no")], structured)))
  error |> should.equal(output.ToolFailed([content.text("no")], structured))
  output.error_kind(error) |> should.equal(output.ToolRefusal)
  output.evidence(error) |> should.equal(client.Completed)
  output.describe_error(error) |> should.equal("no")
}

pub fn discovered_projection_uses_presence_without_guessing_from_schema_test() {
  let blocks = [content.text("a"), content.text("b")]
  output.require_discovered(Ok(client.Succeeded(Some(value.Null), blocks)))
  |> should.equal(Ok(value.Null))
  output.require_discovered(Ok(client.Succeeded(None, blocks)))
  |> should.equal(Ok(value.String("a\nb")))
  output.require_discovered(
    Ok(client.Succeeded(Some(value.Bool(False)), blocks)),
  )
  |> should.equal(Ok(value.Bool(False)))
}

pub fn metadata_keeps_the_normal_structured_text_mirror_test() {
  let definition = tool.define("answer", codec.success(Nil), codec.int())
  let served =
    tool.handle_call(definition, fn(_, _) {
      Ok(tool.complete_with_meta(42, [#("app/id", value.String("r1"))]))
    })
  let peer = testing.connect(server.new([served]), Nil)
  let result = client.call(peer, definition, Nil) |> should.be_ok
  let assert client.Succeeded(42, [content.TextContent(text:, ..)]) = result
  text |> should.equal("42")
  output.meta(result, "app/id") |> should.equal(Some(value.String("r1")))
  output.meta(result, "absent") |> should.equal(None)
  client.close(peer)
}

pub fn metadata_is_also_attached_to_content_only_replies_test() {
  let definition = tool.define_content("answer", codec.success(Nil))
  let served =
    tool.handle_call(definition, fn(_, _) {
      Ok(
        tool.complete_with_meta([content.text("hello")], [
          #("app/id", value.String("r2")),
        ]),
      )
    })
  let peer = testing.connect(server.new([served]), Nil)
  let result = client.call(peer, definition, Nil) |> should.be_ok
  let assert client.Succeeded([content.TextContent(text:, ..)], _) = result
  text |> should.equal("hello")
  output.meta(result, "app/id") |> should.equal(Some(value.String("r2")))
  client.close(peer)
}

/// A schema describes expected values; it cannot prove whether a reply
/// actually carried structuredContent. Check the public decoder and projection.
pub fn discovered_presence_is_independent_of_output_schema_test() {
  presence_cases(fn(declaration, reply, expected, projected) {
    let peer = discovery_peer(reply, 0)
    let result = client.call_discovered(peer, declaration, value.Object([]))
    let assert Ok(client.Succeeded(found, blocks)) = result
    found |> should.equal(expected)
    blocks |> should.equal([content.text("fallback")])
    output.require_discovered(result) |> should.equal(Ok(projected))
    client.close(peer)
  })
}

pub fn discovered_presence_survives_multiple_continuation_rounds_test() {
  presence_cases(fn(declaration, reply, expected, projected) {
    let peer = discovery_peer(reply, 2)
    let assert Ok(client.InputRequired(first, _)) =
      client.call_discovered(peer, declaration, value.Object([]))
    let assert Ok(client.InputRequired(second, _)) =
      client.resume(first, dict.new())
    let result = client.resume(second, dict.new())
    let assert Ok(client.Succeeded(found, blocks)) = result
    found |> should.equal(expected)
    blocks |> should.equal([content.text("fallback")])
    output.require_discovered(result) |> should.equal(Ok(projected))
    client.close(peer)
  })
}

pub fn discovered_projection_retains_refusal_and_transport_evidence_test() {
  let structured = Some(value.Null)
  output.require_discovered(
    Ok(client.ToolFailed([content.text("no")], structured)),
  )
  |> should.equal(Error(output.ToolFailed([content.text("no")], structured)))
  let lost = testing.error(client.TimedOut(client.MaybeSent))
  output.require_discovered(Error(lost))
  |> should.equal(Error(output.CallFailed(lost)))
  let declaration =
    tool.declaration(tool.define_content("lookup", codec.success(Nil)))
  let peer = discovery_peer("null", 2)
  client.call_discovered(peer, declaration, value.Object([]))
  |> output.require_discovered
  |> should.equal(Error(output.InputRequired))
  client.close(peer)
}

fn presence_cases(
  check: fn(tool.Declaration, String, Option(value.Value), value.Value) -> Nil,
) -> Nil {
  let declaration =
    tool.declaration(tool.define("lookup", codec.success(Nil), codec.value()))
  list.each(
    [declaration, tool.Declaration(..declaration, output_schema: None)],
    fn(declaration) {
      list.each(
        [
          #("absent", None, value.String("fallback")),
          #("null", Some(value.Null), value.Null),
          #("{}", Some(value.Object([])), value.Object([])),
        ],
        fn(row) { check(declaration, row.0, row.1, row.2) },
      )
    },
  )
}

fn discovery_peer(reply: String, rounds: Int) -> client.Client {
  let assert Ok(peer) =
    client.stdio("python3", [
      "test/fixtures/stdio/discovered-presence-peer.py",
      reply,
      int.to_string(rounds),
    ])
    |> client.connect
  peer
}
