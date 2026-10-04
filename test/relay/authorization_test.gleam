import gleam/erlang/process
import gleam/http as gleam_http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import json/blueprint/codec
import relay/authorization
import relay/http
import relay/server
import relay/telemetry
import relay/testing
import relay/tool
import sinal
import sinal/correlation

const resource_raw = "https://relay.example/mcp"

const metadata_raw = "https://relay.example/.well-known/oauth-protected-resource/mcp"

fn resource() -> authorization.ProtectedResource {
  let assert Ok(resource) = authorization.protected_resource(resource_raw)
  resource
}

fn scope(name: String) -> authorization.Scope {
  let assert Ok(scope) = authorization.scope(name)
  scope
}

fn token(raw: String) -> authorization.BearerToken {
  let assert Ok(token) = authorization.bearer_token(raw)
  token
}

fn fixed_verifier(
  attestation: authorization.Attestation(String),
) -> authorization.Verifier(String) {
  authorization.verifier("test-verifier", fn(_token, _correlation) {
    Ok(attestation)
  })
}

fn admit(
  verifier: authorization.Verifier(principal),
  token: authorization.BearerToken,
  protection: authorization.Protection,
) -> Result(authorization.Grant(principal), authorization.AdmissionError) {
  authorization.admit(verifier, token, protection, correlation.unique())
}

// --- admission ----------------------------------------------------------------

pub fn admits_verified_principal_and_configured_scope_test() {
  let read = scope("tools:read")
  let verifier =
    fixed_verifier(
      authorization.attestation("principal", [resource_raw], ["tools:read"]),
    )
  let protection = authorization.protection(resource(), [read])
  let assert Ok(grant) = admit(verifier, token("opaque-token"), protection)
  should.equal(authorization.grant_principal(grant), "principal")
  should.equal(authorization.grant_scopes(grant), [read])
  should.equal(authorization.grant_resource(grant), resource())
  authorization.has_scope(grant, read) |> should.be_true
  authorization.has_scope(grant, scope("tools:write")) |> should.be_false
  authorization.verifier_name(verifier) |> should.equal("test-verifier")
}

pub fn rejects_verifier_failure_without_grant_test() {
  let protection = authorization.protection(resource(), [])
  [
    authorization.BearerRejected,
    authorization.VerifierUnavailable,
    authorization.VerifierUnmapped,
  ]
  |> list.each(fn(failure) {
    let verifier =
      authorization.verifier("test-verifier", fn(_token, _correlation) {
        Error(failure)
      })
    admit(verifier, token("expired"), protection)
    |> should.equal(Error(authorization.VerificationFailed(failure)))
  })
}

pub fn rejects_wrong_missing_and_additional_audiences_test() {
  let protection = authorization.protection(resource(), [])
  [
    ["https://other.example/mcp"],
    [resource_raw, "https://other.example/mcp"],
    [],
    ["https://relay.example/mcp/"],
  ]
  |> list.each(fn(audiences) {
    let verifier =
      fixed_verifier(authorization.attestation("principal", audiences, []))
    admit(verifier, token("opaque-token"), protection)
    |> should.equal(Error(authorization.ResourceNotGranted))
  })
  // Empty audience strings are ignored.
  let verifier =
    fixed_verifier(
      authorization.attestation("principal", [resource_raw, ""], []),
    )
  let assert Ok(_) = admit(verifier, token("opaque-token"), protection)
}

pub fn retains_attested_scopes_and_requires_every_endpoint_scope_test() {
  let read = scope("tools:read")
  let write = scope("tools:write")
  let verifier =
    fixed_verifier(
      authorization.attestation("principal", [resource_raw], [
        "tools:read", "tools:write", "",
      ]),
    )
  let admitting = authorization.protection(resource(), [read])
  let assert Ok(grant) = admit(verifier, token("opaque-token"), admitting)
  should.equal(authorization.grant_scopes(grant), [read, write])

  let stronger = authorization.protection(resource(), [read, write])
  let assert Ok(_) = admit(verifier, token("opaque-token"), stronger)
  let weak_verifier =
    fixed_verifier(
      authorization.attestation("principal", [resource_raw], ["tools:read"]),
    )
  admit(weak_verifier, token("weak-token"), stronger)
  |> should.equal(Error(authorization.MissingEndpointScope(write)))
  authorization.required_scopes(stronger) |> should.equal([read, write])
  authorization.protected(stronger) |> should.equal(resource())
}

// --- values -------------------------------------------------------------------

pub fn bearer_token_does_not_print_its_value_test() {
  let secret = "relay-secret-bearer-value"
  let assert Ok(token) = authorization.bearer_token(secret)
  string.contains(string.inspect(token), secret) |> should.be_false
  string.contains(string.inspect(Ok(token)), secret) |> should.be_false
  string.contains(string.inspect(#("authorization", [token])), secret)
  |> should.be_false
  authorization.token_value(token) |> should.equal(secret)
}

pub fn values_are_readable_and_validated_test() {
  authorization.bearer_token("")
  |> should.equal(Error(authorization.EmptyBearerToken))
  authorization.scope("") |> should.equal(Error(authorization.EmptyScope))
  authorization.scope_name(scope("tools:read")) |> should.equal("tools:read")
  authorization.resource_uri(resource()) |> should.equal(resource_raw)
  [
    "http://localhost:8080/mcp",
    "https://relay.example",
    "HTTPS://relay.example/",
  ]
  |> list.each(fn(raw) {
    let assert Ok(resource) = authorization.protected_resource(raw)
    authorization.resource_uri(resource) |> should.equal(raw)
  })
  [
    "", "/mcp", "mcp", "relay.example/mcp", "ftp://relay.example/mcp",
    "urn:relay:mcp", "https://relay.example/mcp#section", "https:///mcp",
  ]
  |> list.each(fn(raw) {
    authorization.protected_resource(raw)
    |> should.equal(Error(authorization.InvalidResource(raw)))
  })
}

pub fn parse_authorization_reads_bearer_tokens_test() {
  ["Bearer abc", "bearer abc", "BEARER abc", "  Bearer   abc  "]
  |> list.each(fn(header) {
    let assert Ok(token) = authorization.parse_authorization(header)
    authorization.token_value(token) |> should.equal("abc")
  })
  ["", "Bearer", "Bearer   ", "Basic abc", "Token abc", "abc"]
  |> list.each(fn(header) {
    case authorization.parse_authorization(header) {
      Error(authorization.MissingToken) -> Nil
      _ -> panic as { "expected MissingToken for " <> string.inspect(header) }
    }
  })
}

pub fn challenges_name_the_metadata_and_the_error_test() {
  let protection =
    authorization.protection(resource(), [
      scope("tools:read"),
      scope("tools:write"),
    ])
  let metadata = "resource_metadata=\"" <> metadata_raw <> "\""
  authorization.challenge(protection, authorization.MissingToken)
  |> should.equal(authorization.Challenge(401, Some("Bearer " <> metadata)))
  authorization.challenge(
    protection,
    authorization.VerificationFailed(authorization.BearerRejected),
  )
  |> should.equal(authorization.Challenge(
    401,
    Some(
      "Bearer error=\"invalid_token\", error_description=\"The access token is invalid or expired\", "
      <> metadata,
    ),
  ))
  authorization.challenge(
    protection,
    authorization.VerificationFailed(authorization.VerifierUnmapped),
  )
  |> should.equal(authorization.Challenge(
    401,
    Some(
      "Bearer error=\"invalid_token\", error_description=\"The access token could not be interpreted\", "
      <> metadata,
    ),
  ))
  authorization.challenge(protection, authorization.ResourceNotGranted)
  |> should.equal(authorization.Challenge(
    401,
    Some(
      "Bearer error=\"invalid_token\", error_description=\"The access token was issued for another resource\", "
      <> metadata,
    ),
  ))
  authorization.challenge(
    protection,
    authorization.VerificationFailed(authorization.VerifierUnavailable),
  )
  |> should.equal(authorization.Challenge(503, None))
  authorization.challenge(
    protection,
    authorization.MissingEndpointScope(scope("tools:write")),
  )
  |> should.equal(authorization.Challenge(
    403,
    Some(
      "Bearer error=\"insufficient_scope\", scope=\"tools:read tools:write\", "
      <> metadata,
    ),
  ))
}

pub fn metadata_location_follows_the_resource_path_test() {
  let at = fn(raw) {
    let assert Ok(resource) = authorization.protected_resource(raw)
    let protection = authorization.protection(resource, [])
    #(
      authorization.metadata_path(protection),
      authorization.metadata_url(protection),
    )
  }
  at(resource_raw)
  |> should.equal(#("/.well-known/oauth-protected-resource/mcp", metadata_raw))
  at("https://relay.example")
  |> should.equal(#(
    "/.well-known/oauth-protected-resource",
    "https://relay.example/.well-known/oauth-protected-resource",
  ))
  at("https://relay.example/")
  |> should.equal(#(
    "/.well-known/oauth-protected-resource",
    "https://relay.example/.well-known/oauth-protected-resource",
  ))
  at("http://localhost:8080/tenants/a/mcp?x=1")
  |> should.equal(#(
    "/.well-known/oauth-protected-resource/tenants/a/mcp",
    "http://localhost:8080/.well-known/oauth-protected-resource/tenants/a/mcp",
  ))
}

pub fn resource_metadata_lists_servers_scopes_and_methods_test() {
  authorization.protection(resource(), [scope("tools:read")])
  |> authorization.with_authorization_servers(["https://auth.example"])
  |> authorization.resource_metadata
  |> json.to_string
  |> should.equal(
    "{\"resource\":\"https://relay.example/mcp\",\"authorization_servers\":[\"https://auth.example\"],\"scopes_supported\":[\"tools:read\"],\"bearer_methods_supported\":[\"header\"]}",
  )
}

// --- the protected HTTP endpoint ----------------------------------------------

fn no_input() -> codec.Codec(Nil) {
  codec.success(Nil)
}

fn principal_tool(name: String) -> tool.Tool(String) {
  tool.define(name, no_input(), codec.string())
  |> tool.handle_call(fn(call, _input) {
    Ok(tool.complete(name <> " for " <> tool.context(call)))
  })
}

fn protected_server() -> server.Server(String) {
  let only_admin_sees_secret = fn(principal, declaration: tool.Declaration) {
    declaration.name != "secret" || principal == "admin"
  }
  server.new([principal_tool("whoami"), principal_tool("secret")])
  |> server.with_tool_access(
    visible: only_admin_sees_secret,
    callable: only_admin_sees_secret,
  )
}

fn protection() -> authorization.Protection {
  authorization.protection(resource(), [scope("tools:read")])
  |> authorization.with_authorization_servers(["https://auth.example"])
}

fn tokens() -> List(#(String, authorization.Attestation(String))) {
  [
    #(
      "alice-token",
      authorization.attestation("alice", [resource_raw], ["tools:read"]),
    ),
    #(
      "admin-token",
      authorization.attestation("admin", [resource_raw], [
        "tools:read", "tools:admin",
      ]),
    ),
    #(
      "foreign-token",
      authorization.attestation("alice", ["https://other.example/mcp"], [
        "tools:read",
      ]),
    ),
    #("weak-token", authorization.attestation("alice", [resource_raw], [])),
  ]
}

fn protected_handler(
  verifier: authorization.Verifier(String),
  grants: process.Subject(authorization.Grant(String)),
) -> http.Handler(String) {
  let assert Ok(handler) =
    http.new_protected(
      protected_server(),
      verifier,
      protection(),
      fn(_request, grant) {
        process.send(grants, grant)
        Ok(authorization.grant_principal(grant))
      },
    )
    |> http.handler
  handler
}

fn bearer(
  request: request.Request(BitArray),
  token: String,
) -> request.Request(BitArray) {
  request.set_header(request, "authorization", "Bearer " <> token)
}

fn call(name: String) -> request.Request(BitArray) {
  testing.request("tools/call", [
    #("name", json.string(name)),
    #("arguments", json.object([])),
  ])
}

fn observe_decisions() -> #(
  process.Subject(telemetry.AuthorizationDecidedMeta),
  sinal.Attachment,
) {
  let decided = process.new_subject()
  let attachment =
    sinal.observe(telemetry.authorization_decided_event(), fn(_, meta) {
      process.send(decided, meta)
    })
  #(decided, attachment)
}

fn next_decision(
  decided: process.Subject(telemetry.AuthorizationDecidedMeta),
) -> telemetry.Decision {
  let assert Ok(meta) = process.receive(decided, 1000)
  meta.verifier |> should.equal("relay-testing")
  meta.decision
}

pub fn protected_endpoint_challenges_refused_requests_test() {
  let grants = process.new_subject()
  let handler = protected_handler(testing.verifier(tokens()), grants)
  let #(decided, attachment) = observe_decisions()
  let rejected = process.new_subject()
  let rejections =
    sinal.observe(telemetry.http_rejected_event(), fn(_, meta) {
      process.send(rejected, meta)
    })

  let missing = http.handle(handler, call("whoami"))
  missing.status |> should.equal(401)
  response.get_header(missing, "www-authenticate")
  |> should.equal(Ok("Bearer resource_metadata=\"" <> metadata_raw <> "\""))
  next_decision(decided) |> should.equal(telemetry.MissingToken)
  let assert Ok(telemetry.HttpRejectedMeta(
    status: 401,
    reason: telemetry.Unauthenticated,
    ..,
  )) = process.receive(rejected, 1000)

  let other_scheme =
    http.handle(
      handler,
      call("whoami") |> request.set_header("authorization", "Basic YWxpY2U="),
    )
  other_scheme.status |> should.equal(401)
  next_decision(decided) |> should.equal(telemetry.MissingToken)

  let unknown = http.handle(handler, bearer(call("whoami"), "stolen-token"))
  unknown.status |> should.equal(401)
  let assert Ok(challenge) = response.get_header(unknown, "www-authenticate")
  string.contains(challenge, "error=\"invalid_token\"") |> should.be_true
  string.contains(challenge, metadata_raw) |> should.be_true
  next_decision(decided) |> should.equal(telemetry.InvalidToken)

  let foreign = http.handle(handler, bearer(call("whoami"), "foreign-token"))
  foreign.status |> should.equal(401)
  let assert Ok(challenge) = response.get_header(foreign, "www-authenticate")
  string.contains(challenge, "error=\"invalid_token\"") |> should.be_true
  next_decision(decided) |> should.equal(telemetry.WrongResource)

  let weak = http.handle(handler, bearer(call("whoami"), "weak-token"))
  weak.status |> should.equal(403)
  let assert Ok(challenge) = response.get_header(weak, "www-authenticate")
  string.contains(
    challenge,
    "error=\"insufficient_scope\", scope=\"tools:read\"",
  )
  |> should.be_true
  next_decision(decided) |> should.equal(telemetry.InsufficientScope)

  // No refused request reached the context builder.
  process.receive(grants, 0) |> should.equal(Error(Nil))
  let assert Ok(Nil) = sinal.detach(rejections)
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn unavailable_verifier_answers_503_without_challenge_test() {
  let grants = process.new_subject()
  let handler = protected_handler(testing.unavailable_verifier(), grants)
  let #(decided, attachment) = observe_decisions()
  let response = http.handle(handler, bearer(call("whoami"), "alice-token"))
  response.status |> should.equal(503)
  response.get_header(response, "www-authenticate") |> should.equal(Error(Nil))
  next_decision(decided) |> should.equal(telemetry.VerifierUnavailable)
  process.receive(grants, 0) |> should.equal(Error(Nil))
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn granted_request_builds_its_context_from_the_grant_test() {
  let grants = process.new_subject()
  let handler = protected_handler(testing.verifier(tokens()), grants)
  let #(decided, attachment) = observe_decisions()
  let response = http.handle(handler, bearer(call("whoami"), "alice-token"))
  response.status |> should.equal(200)
  string.contains(testing.body_text(response), "whoami for alice")
  |> should.be_true
  next_decision(decided) |> should.equal(telemetry.Granted)
  let assert Ok(grant) = process.receive(grants, 1000)
  authorization.grant_principal(grant) |> should.equal("alice")
  authorization.grant_scopes(grant)
  |> list.map(authorization.scope_name)
  |> should.equal(["tools:read"])
  authorization.grant_resource(grant) |> should.equal(resource())
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn protected_endpoint_serves_resource_metadata_test() {
  let handler =
    protected_handler(testing.verifier(tokens()), process.new_subject())
  let metadata_request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_host("127.0.0.1")
    |> request.set_path(authorization.metadata_path(protection()))
    |> request.set_body(<<>>)
  let response = http.handle(handler, metadata_request)
  response.status |> should.equal(200)
  response.get_header(response, "content-type")
  |> should.equal(Ok("application/json"))
  testing.body_text(response)
  |> should.equal(json.to_string(authorization.resource_metadata(protection())))
  let body = testing.body_text(response)
  string.contains(body, "\"resource\":\"" <> resource_raw <> "\"")
  |> should.be_true
  string.contains(body, "\"authorization_servers\":[\"https://auth.example\"]")
  |> should.be_true
  string.contains(body, "\"scopes_supported\":[\"tools:read\"]")
  |> should.be_true
  string.contains(body, "\"bearer_methods_supported\":[\"header\"]")
  |> should.be_true
  // Any other GET is still refused.
  let other = http.handle(handler, request.set_path(metadata_request, "/mcp"))
  other.status |> should.equal(405)
}

pub fn tool_access_follows_the_principal_in_the_context_test() {
  let handler =
    protected_handler(testing.verifier(tokens()), process.new_subject())
  let listing = fn(token) {
    http.handle(handler, bearer(testing.request("tools/list", []), token))
    |> testing.body_text
  }
  let alice_tools = listing("alice-token")
  string.contains(alice_tools, "\"whoami\"") |> should.be_true
  string.contains(alice_tools, "\"secret\"") |> should.be_false
  let admin_tools = listing("admin-token")
  string.contains(admin_tools, "\"whoami\"") |> should.be_true
  string.contains(admin_tools, "\"secret\"") |> should.be_true

  // A hidden tool answers like an unknown one.
  let denied = http.handle(handler, bearer(call("secret"), "alice-token"))
  string.contains(testing.body_text(denied), "-32602") |> should.be_true
  let unknown = http.handle(handler, bearer(call("missing"), "alice-token"))
  string.contains(testing.body_text(unknown), "-32602") |> should.be_true
  let allowed = http.handle(handler, bearer(call("secret"), "admin-token"))
  allowed.status |> should.equal(200)
  string.contains(testing.body_text(allowed), "secret for admin")
  |> should.be_true
}

// --- wave 5: audience refusals and correlation ---------------------------------

/// A verifier that checks the audience itself reports
/// `IssuedForAnotherResource`, and Relay answers with the same challenge and
/// decision as an attestation for another resource.
pub fn issued_for_another_resource_gets_the_resource_challenge_test() {
  let protection = protection()
  let refusing =
    authorization.verifier("audience-checking", fn(_token, _correlation) {
      Error(authorization.IssuedForAnotherResource)
    })
  admit(refusing, token("foreign"), protection)
  |> should.equal(
    Error(authorization.VerificationFailed(
      authorization.IssuedForAnotherResource,
    )),
  )
  authorization.challenge(
    protection,
    authorization.VerificationFailed(authorization.IssuedForAnotherResource),
  )
  |> should.equal(authorization.challenge(
    protection,
    authorization.ResourceNotGranted,
  ))

  let grants = process.new_subject()
  let handler = protected_handler(refusing, grants)
  let decided = process.new_subject()
  let attachment =
    sinal.observe(telemetry.authorization_decided_event(), fn(_, meta) {
      case meta.verifier {
        "audience-checking" -> process.send(decided, meta.decision)
        _ -> Nil
      }
    })
  let response = http.handle(handler, bearer(call("whoami"), "foreign"))
  response.status |> should.equal(401)
  response.get_header(response, "www-authenticate")
  |> should.equal(Ok(
    "Bearer error=\"invalid_token\", error_description=\"The access token was issued for another resource\", resource_metadata=\""
    <> metadata_raw
    <> "\"",
  ))
  process.receive(decided, 1000) |> should.equal(Ok(telemetry.WrongResource))
  process.receive(grants, 0) |> should.equal(Error(Nil))
  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn verification_errors_have_a_stable_kind_test() {
  [
    #(authorization.BearerRejected, authorization.InvalidToken),
    #(authorization.VerifierUnmapped, authorization.InvalidToken),
    #(authorization.IssuedForAnotherResource, authorization.InvalidToken),
    #(authorization.VerifierUnavailable, authorization.Unavailable),
  ]
  |> list.each(fn(pair) {
    authorization.verification_kind(pair.0) |> should.equal(pair.1)
    let assert False = authorization.describe_verification_error(pair.0) == ""
  })
  authorization.describe_verification_error(
    authorization.IssuedForAnotherResource,
  )
  |> should.equal("the access token was issued for another resource")
}

pub fn admit_hands_the_correlation_to_the_verifier_test() {
  let seen = process.new_subject()
  let verifier =
    authorization.verifier("correlated", fn(_token, correlation) {
      process.send(seen, correlation)
      Ok(authorization.attestation("principal", [resource_raw], []))
    })
  let correlation = correlation.from_key("admission-17")
  let assert Ok(_) =
    authorization.admit(
      verifier,
      token("t"),
      authorization.protection(resource(), []),
      correlation,
    )
  process.receive(seen, 0) |> should.equal(Ok(correlation))
  authorization.verifier_name(verifier) |> should.equal("correlated")
}

fn correlation_tool() -> tool.Tool(String) {
  tool.define("whoami", no_input(), codec.string())
  |> tool.handle_call(fn(call, _input) {
    Ok(tool.complete(correlation.to_string(tool.correlation(call))))
  })
}

/// Wave 5: the verifier, the authorization decision and the handler see the
/// one correlation of the request, whether the client sent it or Relay
/// minted it.
pub fn verifier_decision_and_handler_share_the_request_correlation_test() {
  let seen = process.new_subject()
  let verifier =
    authorization.verifier("correlated", fn(token, correlation) {
      process.send(seen, correlation)
      list.key_find(tokens(), authorization.token_value(token))
      |> result.replace_error(authorization.BearerRejected)
    })
  let assert Ok(handler) =
    http.new_protected(
      server.new([correlation_tool()]),
      verifier,
      protection(),
      fn(_request, grant) { Ok(authorization.grant_principal(grant)) },
    )
    |> http.handler
  let decided = process.new_subject()
  let attachment =
    sinal.observe(telemetry.authorization_decided_event(), fn(_, meta) {
      case meta.verifier {
        "correlated" -> process.send(decided, meta.correlation)
        _ -> Nil
      }
    })

  let sent =
    bearer(call("whoami"), "alice-token")
    |> request.set_header("x-correlation-id", "question-9")
  let response = http.handle(handler, sent)
  response.status |> should.equal(200)
  let assert Ok(question) = correlation.from_string("question-9")
  process.receive(seen, 1000) |> should.equal(Ok(question))
  process.receive(decided, 1000) |> should.equal(Ok(question))
  string.contains(testing.body_text(response), "question-9") |> should.be_true

  let response = http.handle(handler, bearer(call("whoami"), "alice-token"))
  response.status |> should.equal(200)
  let assert Ok(minted) = process.receive(seen, 1000)
  process.receive(decided, 1000) |> should.equal(Ok(minted))
  string.contains(testing.body_text(response), correlation.to_string(minted))
  |> should.be_true

  // A refused request still names its correlation.
  let refused =
    bearer(call("whoami"), "stolen-token")
    |> request.set_header("x-correlation-id", "question-10")
  http.handle(handler, refused).status |> should.equal(401)
  let assert Ok(refused_correlation) = correlation.from_string("question-10")
  process.receive(seen, 1000) |> should.equal(Ok(refused_correlation))
  process.receive(decided, 1000) |> should.equal(Ok(refused_correlation))
  let assert Ok(Nil) = sinal.detach(attachment)
}
