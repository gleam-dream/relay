import json/blueprint/value.{type Value}
import relay/tool.{type ToolDeclaration}

/// Opaque bearer token.
pub opaque type BearerToken {
  BearerToken(String)
}

/// Validated resource identifier.
pub opaque type Resource {
  Resource(String)
}

/// Validated scope.
pub opaque type Scope {
  Scope(String)
}

pub type BoundaryValueError {
  EmptyBearerToken
  EmptyResource
  EmptyScope
}

pub fn bearer_token(raw: String) -> Result(BearerToken, BoundaryValueError) {
  case raw {
    "" -> Error(EmptyBearerToken)
    _ -> Ok(BearerToken(raw))
  }
}

pub fn resource(raw: String) -> Result(Resource, BoundaryValueError) {
  case raw {
    "" -> Error(EmptyResource)
    _ -> Ok(Resource(raw))
  }
}

pub fn scope(raw: String) -> Result(Scope, BoundaryValueError) {
  case raw {
    "" -> Error(EmptyScope)
    _ -> Ok(Scope(raw))
  }
}

pub opaque type ProtectionConfig {
  ProtectionConfig(resource: Resource, required_scopes: List(Scope))
}

pub fn protection_config(
  resource: Resource,
  required_scopes: List(Scope),
) -> ProtectionConfig {
  ProtectionConfig(resource, required_scopes)
}

pub type VerifierDeclaration {
  VerifierDeclaration(name: String, version: String)
}

pub opaque type Verifier(principal) {
  Verifier(
    declaration: VerifierDeclaration,
    verify: fn(BearerToken) -> Result(principal, String),
  )
}

pub opaque type GrantedRequest(principal) {
  GrantedRequest(principal: principal, resource: Resource, scopes: List(Scope))
}

pub type Visibility {
  Visible
  Hidden
}

pub type ExecutionAuthorization {
  ExecutionAuthorized
  ExecutionUnauthorized
}

pub type InaccessibleCause {
  UnknownTool
  HiddenTool
  ExecutionDenied
}

pub type ProtectedDispatchError {
  Inaccessible(InaccessibleCause)
  InvocationFailed(tool.DispatchError)
}

pub opaque type ToolPolicy(context, principal) {
  ToolPolicy(
    visibility: fn(context, GrantedRequest(principal), ToolDeclaration) ->
      Visibility,
    execution: fn(context, GrantedRequest(principal), ToolDeclaration) ->
      ExecutionAuthorization,
  )
}

pub fn tool_policy(
  visibility: fn(context, GrantedRequest(principal), ToolDeclaration) ->
    Visibility,
  execution: fn(context, GrantedRequest(principal), ToolDeclaration) ->
    ExecutionAuthorization,
) -> ToolPolicy(context, principal) {
  ToolPolicy(visibility, execution)
}

pub opaque type ProtectedRegistry(context, principal) {
  ProtectedRegistry(
    protection: ProtectionConfig,
    policy: ToolPolicy(context, principal),
  )
}

/// Resource server protected registry constructor.
/// Deferred to Wave 4: Resource-server authorization.
pub fn protect_registry(
  _protection: ProtectionConfig,
  _policy: ToolPolicy(context, principal),
) -> ProtectedRegistry(context, principal) {
  todo as "wave 4: Resource-server authorization"
}

/// Verifies a bearer token and admits a granted request.
/// Deferred to Wave 4: Resource-server authorization.
pub fn admit(
  _verifier: Verifier(principal),
  _token: BearerToken,
  _config: ProtectionConfig,
) -> Result(GrantedRequest(principal), String) {
  todo as "wave 4: Resource-server authorization"
}

/// Dispatches a tool call through the protected registry.
/// Deferred to Wave 4: Resource-server authorization.
pub fn dispatch_granted(
  _registry: ProtectedRegistry(context, principal),
  _context: context,
  _grant: GrantedRequest(principal),
  _name: tool.ToolName,
  _arguments: Value,
) -> Result(Value, ProtectedDispatchError) {
  todo as "wave 4: Resource-server authorization"
}
