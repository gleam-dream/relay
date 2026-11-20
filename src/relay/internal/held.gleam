//// A value held once in node-wide shared storage. Processes that read it
//// refer to the one stored copy: passing the handle, or the value read from
//// it, to another process copies neither. The holder's exit or `release`
//// frees it. Storing or freeing a value scans every process on the node, so
//// a holder replaces its value only on rare changes.

/// The handle to a held value. It is small and cheap to copy.
pub type Held(value)

/// Holds `value` until `release` or until the calling process exits.
@external(erlang, "relay_ffi", "hold")
pub fn hold(value: value) -> Held(value)

/// The held value. Panics after `release` or after the holder exited.
@external(erlang, "relay_ffi", "held_get")
pub fn get(held: Held(value)) -> value

/// Frees the held value. Readers that still refer to it keep a private copy.
@external(erlang, "relay_ffi", "release")
pub fn release(held: Held(value)) -> Nil
