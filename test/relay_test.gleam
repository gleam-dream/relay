import gleeunit
import gleeunit/should
import relay

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn version_test() {
  relay.version()
  |> should.equal("0.1.0")
}
