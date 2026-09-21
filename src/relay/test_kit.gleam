import relay/server.{type Server}

/// Scripted peer for testing client interactions.
pub opaque type ScriptedPeer {
  ScriptedPeer(name: String)
}

/// Fake clock for deterministic timing tests.
pub opaque type FakeClock {
  FakeClock(ticks: Int)
}

/// Constructs a paired in-memory transport for testing.
/// Deferred to Wave 5: Typed client and test kit.
pub fn paired_transport(_server: Server(context)) -> Nil {
  todo as "wave 5: Typed client and test kit"
}

/// Constructs a scripted peer.
/// Deferred to Wave 5: Typed client and test kit.
pub fn scripted_peer() -> ScriptedPeer {
  todo as "wave 5: Typed client and test kit"
}

/// Constructs a fake clock.
/// Deferred to Wave 5: Typed client and test kit.
pub fn fake_clock() -> FakeClock {
  todo as "wave 5: Typed client and test kit"
}
