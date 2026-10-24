//// Every usage example runs here, so a change to Relay's public API that breaks
//// a documented recipe fails the examples gate.

import gleeunit
import relay_usage/call_controls
import relay_usage/correlation
import relay_usage/mount
import relay_usage/protect
import relay_usage/serve_and_call
import relay_usage/typed_output

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn serve_and_call_test() {
  serve_and_call.run()
}

pub fn mount_test() {
  mount.run()
}

pub fn protect_test() {
  protect.run()
}

pub fn call_controls_test() {
  call_controls.run()
}

pub fn correlation_test() {
  correlation.run()
}

pub fn typed_output_test() {
  typed_output.run()
}
