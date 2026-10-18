//// Protect the endpoint. `http.new_protected` reads the bearer token, asks
//// your verifier, admits the request for the protected resource and its
//// scopes, answers a refusal with the RFC 6750 challenge and serves the
//// RFC 9728 metadata document. Relay never parses tokens: the verifier owns
//// signatures, expiry and issuers.
////
//// Run: `gleam run -m relay_usage/protect`

import gleam/http/request
import gleam/http/response
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import json/blueprint/codec
import relay/authorization
import relay/http
import relay/server
import relay/testing
import relay/tool
import sinal/correlation.{type Correlation}

pub type Claims {
  Claims(subject: String, audiences: List(String), scopes: List(String))
}

pub fn protect(
  service: server.Server(Claims),
  validate: fn(String) -> Result(Claims, Nil),
) -> http.Config(Claims) {
  let assert Ok(resource) =
    authorization.protected_resource("https://mcp.example.com/mcp")
  let assert Ok(reports) = authorization.scope("reports")
  let protection =
    authorization.protection(resource, [reports])
    |> authorization.with_authorization_servers(["https://login.example.com"])
  let verifier = {
    use token, _correlation <- authorization.verifier("jwt")
    validate(authorization.token_value(token))
    |> result.map(fn(c) { authorization.attestation(c, c.audiences, c.scopes) })
    |> result.replace_error(authorization.BearerRejected)
  }
  http.new_protected(service, verifier, protection, fn(_request, grant) {
    Ok(authorization.grant_principal(grant))
  })
}

/// The verifier also receives the request's correlation, so an introspection
/// call joins the request's telemetry.
pub fn introspecting_verifier(
  introspect: fn(authorization.BearerToken, Correlation) ->
    Result(authorization.Attestation(String), authorization.VerificationError),
) -> authorization.Verifier(String) {
  use token, correlation <- authorization.verifier("introspection")
  introspect(token, correlation)
}

pub fn run() -> Nil {
  let claims =
    Claims("ada", ["https://mcp.example.com/mcp"], ["reports", "profile"])
  let validate = fn(token) {
    case token {
      "good" -> Ok(claims)
      _ -> Error(Nil)
    }
  }
  let subject =
    tool.define("subject", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      let claims: Claims = tool.context(call)
      Ok(tool.complete(claims.subject))
    })
  let assert Ok(mcp) =
    protect(server.new([subject]), validate)
    |> http.with_allowed_hosts(["127.0.0.1"])
    |> http.handler
  let call =
    testing.request("tools/call", [
      #("name", json.string("subject")),
      #("arguments", json.object([])),
    ])
  // No token: 401 with the RFC 6750 challenge pointing at the metadata.
  let refused = http.handle(mcp, call)
  let assert 401 = refused.status
  let assert Ok(challenge) = response.get_header(refused, "www-authenticate")
  let assert True = string.contains(challenge, "resource_metadata=")
  // A token the verifier accepts reaches the handler as its principal.
  let granted =
    http.handle(mcp, request.set_header(call, "authorization", "Bearer good"))
  let assert 200 = granted.status
  let assert True = string.contains(testing.body_text(granted), "ada")
  http.stop(mcp)

  // A verifier that checks the audience itself reports a token issued for
  // another resource; branch on the kind, not the variants.
  let verifier =
    introspecting_verifier(fn(_token, _correlation) {
      Error(authorization.IssuedForAnotherResource)
    })
  let assert Ok(token) = authorization.bearer_token("t")
  let assert Ok(resource) =
    authorization.protected_resource("https://mcp.example.com/mcp")
  let assert Error(authorization.VerificationFailed(error)) =
    authorization.admit(
      verifier,
      token,
      authorization.protection(resource, []),
      correlation.unique(),
    )
  let assert authorization.InvalidToken = authorization.verification_kind(error)
  Nil
}

pub fn main() -> Nil {
  run()
  io.println("protect: ok")
}
