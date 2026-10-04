//// Test helper: a client result with its error replaced by the failure, so
//// a test can match `Error(client.RpcError(..))` directly.

import gleam/result
import relay/client

/// The result with `client.reason` applied to its error.
pub fn of(outcome: Result(a, client.Error)) -> Result(a, client.Reason) {
  result.map_error(outcome, client.reason)
}
