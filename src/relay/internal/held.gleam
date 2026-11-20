//// A value held once in node-wide shared storage. Processes that read it
//// refer to the one stored copy: passing the handle, or the value read from
//// it, to another process copies neither. The holder's exit or `release`
//// frees it. Storing copies the value once, at a cost that also grows with
//// the number of stored terms; freeing makes every process on the node check
//// its heap for the value, so holders free values only on rare changes and
//// at shutdown. Shared reads hold on OTP 29, where the copy-cost tests run.

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
