import gleam/option.{None, Some}
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

pub fn discovered_content_projection_preserves_structured_null_test() {
  let definition = tool.define("lookup", codec.success(Nil), codec.value())
  let declaration = tool.declaration(definition)
  let result =
    Ok(client.Succeeded(value.Null, [content.text("a"), content.text("b")]))
  output.require_discovered(result, declaration) |> should.equal(Ok(value.Null))
  output.require_discovered(
    result,
    tool.Declaration(..declaration, output_schema: None),
  )
  |> should.equal(Ok(value.String("a\nb")))
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
