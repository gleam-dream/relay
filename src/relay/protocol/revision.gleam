/// Protocol revisions supported or recognized by Relay.
pub type ProtocolRevision {
  /// MCP 2026-07-28: modern, sessionless revision with per-request _meta.
  Revision20260728
  /// MCP 2025-11-25: legacy revision requiring initialize handshake and sessions.
  Revision20251125
}

/// Returns the protocol revision string for wire envelopes.
pub fn to_string(revision: ProtocolRevision) -> String {
  case revision {
    Revision20260728 -> "2026-07-28"
    Revision20251125 -> "2025-11-25"
  }
}

/// Supported versions for the MCP 2026-07-28 server.
pub fn supported_versions() -> List(String) {
  ["2026-07-28"]
}
