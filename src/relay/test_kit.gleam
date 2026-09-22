import relay/server.{type Server}

/// Scripted peer for testing client interactions.
pub opaque type ScriptedPeer {
  ScriptedPeer(name: String)
}

/// Fake clock for deterministic timing tests.
pub opaque type FakeClock {
  FakeClock(ticks: Int)
}

/// Constructs the current in-memory transport marker used by deterministic
/// tests. Runtime transport wiring remains owned by the test process.
pub fn paired_transport(_server: Server(context)) -> Nil {
  Nil
}

/// Constructs a named scripted-peer marker for table-driven tests.
pub fn scripted_peer() -> ScriptedPeer {
  ScriptedPeer("scripted-peer")
}

/// Constructs a deterministic fake clock starting at tick zero.
pub fn fake_clock() -> FakeClock {
  FakeClock(0)
}

/// Returns the current fake tick.
pub fn fake_clock_ticks(clock: FakeClock) -> Int {
  clock.ticks
}

/// Advances a fake clock without sleeping.
pub fn advance_fake_clock(clock: FakeClock, by ticks: Int) -> FakeClock {
  FakeClock(clock.ticks + ticks)
}
