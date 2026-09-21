/// Resource URI.
pub opaque type ResourceUri {
  ResourceUri(String)
}

/// Lists resources available on the server.
/// Deferred to Wave 2: Complete modern server core.
pub fn list_resources() -> Nil {
  todo as "wave 2: Complete modern server core"
}

/// Reads a resource by URI.
/// Deferred to Wave 2: Complete modern server core.
pub fn read_resource(_uri: ResourceUri) -> Nil {
  todo as "wave 2: Complete modern server core"
}
