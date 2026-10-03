//// Bearer-token authorization for an MCP resource server: tokens, the
//// protected resource and its scopes, a verifier, admission, RFC 6750
//// challenges and RFC 9728 protected-resource metadata.
////
//// A `Verifier` is a function the application supplies: it receives the
//// `BearerToken` and returns an `Attestation` of the principal, the
//// audiences and the scopes, or a `VerificationError`. Relay never parses or
//// checks a token itself; the verifier owns signatures, expiry, issuers and
//// any introspection call. `admit` then accepts the attestation only when it
//// names exactly the protected resource as its one audience and carries
//// every required scope, and returns a `Grant`.
////
//// `relay/http.new_protected` wires this module into the HTTP endpoint: it
//// reads the `Authorization` header, answers a refusal with the `challenge`
//// status and `WWW-Authenticate` header, and serves `resource_metadata` at
//// `metadata_path`. Use the functions directly for a custom transport.
////
//// A token, a scope and a resource are readable (`token_value`,
//// `scope_name`, `resource_uri`), so a verifier can pass the token to a
//// validator. A `BearerToken` keeps its value inside a closure, so
//// `string.inspect`, crash reports and logs print a function reference
//// instead of the token.
////
//// A local JWT validator plugs in as the verifier. With a validator that
//// returns claims holding `subject`, `audiences` and `scopes`, the
//// verifier is one expression:
////
//// ```gleam
//// import gleam/result
//// import relay/authorization
////
//// pub type Claims {
////   Claims(subject: String, audiences: List(String), scopes: List(String))
//// }
////
//// pub fn verifier(
////   validate: fn(String) -> Result(Claims, Nil),
//// ) -> authorization.Verifier(Claims) {
////   use token <- authorization.verifier("jwt")
////   validate(authorization.token_value(token))
////   |> result.map(fn(claims) {
////     authorization.attestation(claims, claims.audiences, claims.scopes)
////   })
////   |> result.replace_error(authorization.BearerRejected)
//// }
//// ```

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

/// A bearer token. Read it with `token_value` inside a verifier.
pub opaque type BearerToken {
  BearerToken(reveal: fn() -> String)
}

/// The resource server's canonical URI, the audience a token must name.
pub opaque type ProtectedResource {
  ProtectedResource(String)
}

/// An OAuth scope.
pub opaque type Scope {
  Scope(String)
}

/// Why a token, resource or scope was refused.
pub type ValueError {
  EmptyBearerToken
  InvalidResource(uri: String)
  EmptyScope
}

/// A token from its raw value.
pub fn bearer_token(raw: String) -> Result(BearerToken, ValueError) {
  case raw {
    "" -> Error(EmptyBearerToken)
    _ -> Ok(BearerToken(reveal: fn() { raw }))
  }
}

/// The token's raw value, to hand to a validator. Do not log it.
pub fn token_value(token: BearerToken) -> String {
  token.reveal()
}

/// The protected resource from an absolute `http` or `https` URI without a
/// fragment, such as `https://mcp.example.com/mcp`.
pub fn protected_resource(
  raw: String,
) -> Result(ProtectedResource, ValueError) {
  case uri.parse(raw) {
    Ok(uri.Uri(scheme: Some(scheme), host: Some(host), fragment: None, ..))
      if host != ""
    ->
      case string.lowercase(scheme) {
        "http" | "https" -> Ok(ProtectedResource(raw))
        _ -> Error(InvalidResource(raw))
      }
    _ -> Error(InvalidResource(raw))
  }
}

/// The resource URI.
pub fn resource_uri(resource: ProtectedResource) -> String {
  let ProtectedResource(raw) = resource
  raw
}

/// A scope from its name.
pub fn scope(raw: String) -> Result(Scope, ValueError) {
  case raw {
    "" -> Error(EmptyScope)
    _ -> Ok(Scope(raw))
  }
}

/// The scope's name.
pub fn scope_name(scope: Scope) -> String {
  let Scope(raw) = scope
  raw
}

// --- protection --------------------------------------------------------------

/// What an endpoint requires: the resource, the scopes every request
/// needs, and the authorization servers its metadata names.
pub opaque type Protection {
  Protection(
    resource: ProtectedResource,
    required_scopes: List(Scope),
    authorization_servers: List(String),
  )
}

/// Protection for one resource with the scopes every request needs.
pub fn protection(
  resource: ProtectedResource,
  required_scopes: List(Scope),
) -> Protection {
  Protection(resource, required_scopes, [])
}

/// Names the authorization servers, by issuer URI, that issue tokens for
/// this resource; `resource_metadata` lists them.
pub fn with_authorization_servers(
  protection: Protection,
  issuers: List(String),
) -> Protection {
  Protection(..protection, authorization_servers: issuers)
}

/// The protected resource.
pub fn protected(protection: Protection) -> ProtectedResource {
  protection.resource
}

/// The scopes every request needs.
pub fn required_scopes(protection: Protection) -> List(Scope) {
  protection.required_scopes
}

// --- verification ------------------------------------------------------------

/// What a verifier asserts about a token it accepted: the principal, the
/// audiences the token was issued for, and its scopes. An attestation is
/// the verifier's claim, not cryptographic proof.
pub opaque type Attestation(principal) {
  Attestation(
    principal: principal,
    audiences: List(String),
    scopes: List(String),
  )
}

/// An attestation from the verifier's validated claims. Empty audience and
/// scope strings are ignored.
pub fn attestation(
  principal: principal,
  audiences: List(String),
  scopes: List(String),
) -> Attestation(principal) {
  Attestation(
    principal: principal,
    audiences: list.filter(audiences, fn(audience) { audience != "" }),
    scopes: list.filter(scopes, fn(scope) { scope != "" }),
  )
}

/// Why a verifier refused a token.
pub type VerificationError {
  /// The token is invalid, expired, revoked or not trusted: 401.
  BearerRejected
  /// The verifier could not decide, for example the key set or the
  /// introspection endpoint is unreachable: 503.
  VerifierUnavailable
  /// The token is valid but its claims could not be mapped to a principal:
  /// 401.
  VerifierUnmapped
}

/// A token verifier with a name for telemetry.
pub opaque type Verifier(principal) {
  Verifier(
    name: String,
    verify: fn(BearerToken) -> Result(Attestation(principal), VerificationError),
  )
}

/// A verifier from the application's validation function. `name`, such as
/// `"jwt"` or `"introspection"`, appears in telemetry.
pub fn verifier(
  name: String,
  verify: fn(BearerToken) -> Result(Attestation(principal), VerificationError),
) -> Verifier(principal) {
  Verifier(name, verify)
}

/// The verifier's name.
pub fn verifier_name(verifier: Verifier(principal)) -> String {
  verifier.name
}

// --- admission ---------------------------------------------------------------

/// Why a request was not admitted.
pub type AdmissionError {
  /// No `Authorization: Bearer` header, or an empty one.
  MissingToken
  VerificationFailed(VerificationError)
  /// The token was not issued for exactly this resource.
  ResourceNotGranted
  /// The token lacks a scope the endpoint requires.
  MissingEndpointScope(Scope)
}

/// An admitted request: its verified principal, the resource and every
/// scope the token carried.
pub opaque type Grant(principal) {
  Grant(principal: principal, resource: ProtectedResource, scopes: List(Scope))
}

/// The verified principal.
pub fn grant_principal(grant: Grant(principal)) -> principal {
  grant.principal
}

/// The resource the request was admitted for.
pub fn grant_resource(grant: Grant(principal)) -> ProtectedResource {
  grant.resource
}

/// Every scope the token carried.
pub fn grant_scopes(grant: Grant(principal)) -> List(Scope) {
  grant.scopes
}

/// Whether the token carried this scope, for per-tool checks.
pub fn has_scope(grant: Grant(principal), scope: Scope) -> Bool {
  list.contains(grant.scopes, scope)
}

/// Reads the token from an `Authorization` header value, such as
/// `"Bearer abc"`. The scheme is case-insensitive.
pub fn parse_authorization(
  header: String,
) -> Result(BearerToken, AdmissionError) {
  case string.split_once(string.trim(header), " ") {
    Ok(#(scheme, raw)) ->
      case string.lowercase(scheme) {
        "bearer" ->
          case bearer_token(string.trim(raw)) {
            Ok(token) -> Ok(token)
            Error(_) -> Error(MissingToken)
          }
        _ -> Error(MissingToken)
      }
    Error(Nil) -> Error(MissingToken)
  }
}

/// Verifies the token and admits the request when the attestation names
/// exactly the protected resource as its only audience and carries every
/// required scope.
pub fn admit(
  verifier: Verifier(principal),
  token: BearerToken,
  protection: Protection,
) -> Result(Grant(principal), AdmissionError) {
  case verifier.verify(token) {
    Error(error) -> Error(VerificationFailed(error))
    Ok(Attestation(principal, audiences, scopes)) -> {
      let scopes = list.map(scopes, Scope)
      case audiences == [resource_uri(protection.resource)] {
        False -> Error(ResourceNotGranted)
        True ->
          case
            list.find(protection.required_scopes, fn(required) {
              !list.contains(scopes, required)
            })
          {
            Ok(missing) -> Error(MissingEndpointScope(missing))
            Error(Nil) -> Ok(Grant(principal, protection.resource, scopes))
          }
      }
    }
  }
}

// --- challenges and metadata -------------------------------------------------

/// The HTTP answer to a refused request: its status and, for 401 and 403,
/// the `WWW-Authenticate` header value.
pub type Challenge {
  Challenge(status: Int, www_authenticate: Option(String))
}

/// The RFC 6750 challenge for a refusal, carrying the RFC 9728
/// `resource_metadata` URL so a client can discover the authorization
/// server. A missing token answers 401 without an error code, an invalid
/// token or wrong resource 401 `invalid_token`, a missing scope 403
/// `insufficient_scope` with the required scopes, and an unavailable
/// verifier 503 without a challenge.
pub fn challenge(protection: Protection, error: AdmissionError) -> Challenge {
  let metadata = "resource_metadata=\"" <> metadata_url(protection) <> "\""
  case error {
    MissingToken -> Challenge(401, Some("Bearer " <> metadata))
    VerificationFailed(VerifierUnavailable) -> Challenge(503, None)
    VerificationFailed(BearerRejected) ->
      invalid_token(metadata, "The access token is invalid or expired")
    VerificationFailed(VerifierUnmapped) ->
      invalid_token(metadata, "The access token could not be interpreted")
    ResourceNotGranted ->
      invalid_token(
        metadata,
        "The access token was issued for another resource",
      )
    MissingEndpointScope(_) ->
      Challenge(
        403,
        Some(
          "Bearer error=\"insufficient_scope\", scope=\""
          <> string.join(list.map(protection.required_scopes, scope_name), " ")
          <> "\", "
          <> metadata,
        ),
      )
  }
}

fn invalid_token(metadata: String, description: String) -> Challenge {
  Challenge(
    401,
    Some(
      "Bearer error=\"invalid_token\", error_description=\""
      <> description
      <> "\", "
      <> metadata,
    ),
  )
}

/// The path of the RFC 9728 metadata document for this resource:
/// `/.well-known/oauth-protected-resource` followed by the resource's path,
/// such as `/.well-known/oauth-protected-resource/mcp`.
pub fn metadata_path(protection: Protection) -> String {
  let path = case uri.parse(resource_uri(protection.resource)) {
    Ok(parsed) -> parsed.path
    Error(Nil) -> ""
  }
  case path {
    "" | "/" -> "/.well-known/oauth-protected-resource"
    path -> "/.well-known/oauth-protected-resource" <> path
  }
}

/// The absolute URL of the RFC 9728 metadata document.
pub fn metadata_url(protection: Protection) -> String {
  case uri.parse(resource_uri(protection.resource)) {
    Ok(parsed) ->
      uri.Uri(
        ..parsed,
        path: metadata_path(protection),
        query: None,
        fragment: None,
      )
      |> uri.to_string
    Error(Nil) -> metadata_path(protection)
  }
}

/// The RFC 9728 protected-resource metadata document: the resource, its
/// authorization servers, the scopes it requires and the header bearer
/// method.
pub fn resource_metadata(protection: Protection) -> json.Json {
  json.object([
    #("resource", json.string(resource_uri(protection.resource))),
    #(
      "authorization_servers",
      json.array(protection.authorization_servers, json.string),
    ),
    #(
      "scopes_supported",
      json.array(protection.required_scopes, fn(scope) {
        json.string(scope_name(scope))
      }),
    ),
    #("bearer_methods_supported", json.array(["header"], json.string)),
  ])
}
