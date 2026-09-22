import gleeunit
import gleeunit/should
import json/blueprint/value
import relay/authorization
import relay/tool

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn admits_verified_principal_and_configured_scope_test() {
  let assert Ok(token) = authorization.bearer_token("opaque-token")
  let assert Ok(resource) = authorization.resource("https://relay.example/mcp")
  let assert Ok(scope) = authorization.scope("tools:read")
  let verifier =
    authorization.verifier("test-verifier", "1", fn(_token) {
      Ok(authorization.attestation("principal", [resource], [scope]))
    })
  let config = authorization.protection_config(resource, [scope])
  let assert Ok(grant) = authorization.admit(verifier, token, config)
  should.equal(authorization.granted_principal(grant), "principal")
  should.equal(authorization.granted_scopes(grant), [scope])
}

pub fn rejects_verifier_failure_without_grant_test() {
  let assert Ok(token) = authorization.bearer_token("expired")
  let assert Ok(resource) = authorization.resource("https://relay.example/mcp")
  let verifier =
    authorization.verifier("test-verifier", "1", fn(_token) {
      Error(authorization.BearerRejected)
    })
  let config = authorization.protection_config(resource, [])
  should.equal(
    authorization.admit(verifier, token, config),
    Error(authorization.VerificationFailed(authorization.BearerRejected)),
  )
}

pub fn rejects_wrong_and_additional_audiences_test() {
  let assert Ok(token) = authorization.bearer_token("opaque-token")
  let assert Ok(resource) = authorization.resource("https://relay.example/mcp")
  let assert Ok(other) = authorization.resource("https://other.example/mcp")
  let verifier =
    authorization.verifier("test-verifier", "1", fn(_token) {
      Ok(authorization.attestation("principal", [other], []))
    })
  let config = authorization.protection_config(resource, [])
  should.equal(
    authorization.admit(verifier, token, config),
    Error(authorization.ResourceNotGranted),
  )

  let verifier =
    authorization.verifier("test-verifier", "1", fn(_token) {
      Ok(authorization.attestation("principal", [resource, other], []))
    })
  let assert Ok(token) = authorization.bearer_token("opaque-token")
  should.equal(
    authorization.admit(verifier, token, config),
    Error(authorization.ResourceNotGranted),
  )
}

pub fn retains_attested_scopes_and_rechecks_registry_requirements_test() {
  let assert Ok(token) = authorization.bearer_token("opaque-token")
  let assert Ok(resource) = authorization.resource("https://relay.example/mcp")
  let assert Ok(other) = authorization.resource("https://other.example/mcp")
  let assert Ok(read) = authorization.scope("tools:read")
  let assert Ok(write) = authorization.scope("tools:write")
  let verifier =
    authorization.verifier("test-verifier", "1", fn(_token) {
      Ok(authorization.attestation("principal", [resource], [read, write]))
    })
  let admitting_config = authorization.protection_config(resource, [read])
  let assert Ok(grant) = authorization.admit(verifier, token, admitting_config)
  should.equal(authorization.granted_scopes(grant), [read, write])

  let policy =
    authorization.tool_policy(
      fn(_context, _grant, _declaration) { authorization.Visible },
      fn(_context, _grant, _declaration) { authorization.ExecutionAuthorized },
    )
  let assert Ok(tools) = tool.registry([])
  let wrong_resource =
    authorization.protect_registry(
      tools,
      authorization.protection_config(other, []),
      policy,
    )
  should.equal(
    authorization.visible_declarations(wrong_resource, Nil, grant),
    Error(authorization.GrantResourceMismatch),
  )
  let assert Ok(name) = tool.tool_name("missing")
  should.equal(
    authorization.dispatch_granted(wrong_resource, Nil, grant, name, value.Null),
    Error(authorization.GrantUseFailed(authorization.GrantResourceMismatch)),
  )

  let stronger =
    authorization.protect_registry(
      tools,
      authorization.protection_config(resource, [write]),
      policy,
    )
  should.equal(authorization.visible_declarations(stronger, Nil, grant), Ok([]))

  let weak_verifier =
    authorization.verifier("test-verifier", "1", fn(_token) {
      Ok(authorization.attestation("principal", [resource], [read]))
    })
  let assert Ok(weak_token) = authorization.bearer_token("weak-token")
  let assert Ok(weak_grant) =
    authorization.admit(weak_verifier, weak_token, admitting_config)
  should.equal(
    authorization.visible_declarations(stronger, Nil, weak_grant),
    Error(authorization.GrantMissingEndpointScope(write)),
  )
}
