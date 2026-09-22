import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
  VerifierDeclaration(name: String, version: String, purpose: VerifierPurpose)
}

pub type VerifierPurpose {
  TrustedVerifier
  TestOnlyVerifier
}

pub type VerifierAttestation(principal) {
  VerifierAttestation(
    principal: principal,
    audiences: List(Resource),
    scopes: List(Scope),
  )
}

pub type VerificationError {
  BearerRejected
  VerifierUnavailable
  VerifierUnmapped
}

pub type AdmissionError {
  VerificationFailed(VerificationError)
  ResourceNotGranted
  MissingEndpointScope(Scope)
}

pub type GrantUseError {
  GrantResourceMismatch
  GrantMissingEndpointScope(Scope)
}

pub opaque type Verifier(principal) {
  Verifier(
    declaration: VerifierDeclaration,
    verify: fn(BearerToken) ->
      Result(VerifierAttestation(principal), VerificationError),
  )
}

/// Builds a verifier at the resource-server boundary. The verifier owns all
/// token parsing and external key/introspection work; Relay only consumes its
/// typed principal result.
pub fn verifier(
  name: String,
  version: String,
  verify: fn(BearerToken) ->
    Result(VerifierAttestation(principal), VerificationError),
) -> Verifier(principal) {
  Verifier(VerifierDeclaration(name, version, TrustedVerifier), verify)
}

pub fn verifier_declaration(
  name: String,
  version: String,
  purpose: VerifierPurpose,
) -> VerifierDeclaration {
  VerifierDeclaration(name, version, purpose)
}

pub fn trust_verifier(
  declaration: VerifierDeclaration,
  verify: fn(BearerToken) ->
    Result(VerifierAttestation(principal), VerificationError),
) -> Verifier(principal) {
  Verifier(declaration, verify)
}

pub fn attestation(
  principal: principal,
  audiences: List(Resource),
  scopes: List(Scope),
) -> VerifierAttestation(principal) {
  VerifierAttestation(principal, audiences, scopes)
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
  GrantUseFailed(GrantUseError)
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
    registry: tool.Registry(context),
  )
}

/// Binds a policy and endpoint protection to a typed tool registry.
pub fn protect_registry(
  registry: tool.Registry(context),
  protection: ProtectionConfig,
  policy: ToolPolicy(context, principal),
) -> ProtectedRegistry(context, principal) {
  ProtectedRegistry(protection, policy, registry)
}

/// Verifies a bearer token and admits a granted request.
pub fn admit(
  verifier: Verifier(principal),
  token: BearerToken,
  config: ProtectionConfig,
) -> Result(GrantedRequest(principal), AdmissionError) {
  let Verifier(_declaration, verify) = verifier
  case verify(token) {
    Error(reason) -> Error(VerificationFailed(reason))
    Ok(VerifierAttestation(principal, audiences, scopes)) ->
      case audiences {
        [audience] if audience == config.resource ->
          case first_missing_scope(config.required_scopes, scopes) {
            None -> Ok(GrantedRequest(principal, config.resource, scopes))
            Some(missing) -> Error(MissingEndpointScope(missing))
          }
        _ -> Error(ResourceNotGranted)
      }
  }
}

fn first_missing_scope(
  required: List(Scope),
  granted: List(Scope),
) -> Option(Scope) {
  case required {
    [] -> None
    [scope, ..rest] ->
      case list.contains(granted, scope) {
        True -> first_missing_scope(rest, granted)
        False -> Some(scope)
      }
  }
}

fn grant_use(
  protection: ProtectionConfig,
  grant: GrantedRequest(principal),
) -> Result(Nil, GrantUseError) {
  case grant.resource == protection.resource {
    False -> Error(GrantResourceMismatch)
    True ->
      case first_missing_scope(protection.required_scopes, grant.scopes) {
        None -> Ok(Nil)
        Some(scope) -> Error(GrantMissingEndpointScope(scope))
      }
  }
}

/// Returns the resource audience admitted for a request.
pub fn granted_resource(grant: GrantedRequest(principal)) -> Resource {
  grant.resource
}

/// Returns the scopes admitted for a request.
pub fn granted_scopes(grant: GrantedRequest(principal)) -> List(Scope) {
  grant.scopes
}

/// Returns the verified principal carried by a request.
pub fn granted_principal(grant: GrantedRequest(principal)) -> principal {
  grant.principal
}

/// Dispatches a tool call through the protected registry.
pub fn dispatch_granted(
  registry: ProtectedRegistry(context, principal),
  context: context,
  grant: GrantedRequest(principal),
  name: tool.ToolName,
  arguments: Value,
) -> Result(Value, ProtectedDispatchError) {
  case grant_use(registry.protection, grant) {
    Error(reason) -> Error(GrantUseFailed(reason))
    Ok(Nil) ->
      case
        find_tool_declaration(tool.registered_tools(registry.registry), name)
      {
        None -> Error(Inaccessible(UnknownTool))
        Some(declaration) -> {
          let visible = case registry.policy {
            ToolPolicy(visibility, _) -> visibility(context, grant, declaration)
          }
          case visible {
            Hidden -> Error(Inaccessible(HiddenTool))
            Visible -> {
              let allowed = case registry.policy {
                ToolPolicy(_, execution) ->
                  execution(context, grant, declaration)
              }
              case allowed {
                ExecutionUnauthorized -> Error(Inaccessible(ExecutionDenied))
                ExecutionAuthorized ->
                  tool.dispatch(registry.registry, context, name, arguments)
                  |> result.map_error(InvocationFailed)
              }
            }
          }
        }
      }
  }
}

pub fn visible_declarations(
  registry: ProtectedRegistry(context, principal),
  context: context,
  grant: GrantedRequest(principal),
) -> Result(List(ToolDeclaration), GrantUseError) {
  use _ <- result.try(grant_use(registry.protection, grant))
  list.filter_map(tool.registered_tools(registry.registry), fn(candidate) {
    let declaration = tool.tool_declaration_of(candidate)
    case registry.policy {
      ToolPolicy(visibility, _) ->
        case visibility(context, grant, declaration) {
          Visible -> Ok(declaration)
          Hidden -> Error(Nil)
        }
    }
  })
  |> Ok
}

fn find_tool_declaration(
  tools: List(tool.ContextTool(context)),
  name: tool.ToolName,
) -> Option(ToolDeclaration) {
  case tools {
    [] -> None
    [candidate, ..rest] -> {
      let declaration = tool.tool_declaration_of(candidate)
      case tool.tool_name_of(candidate) == name {
        True -> Some(declaration)
        False -> find_tool_declaration(rest, name)
      }
    }
  }
}
