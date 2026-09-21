import gleam/list
import relay/resources.{type ResourceUri, resource_uri_to_string}

/// A subscription registry owned by one Relay server runtime.
pub opaque type Subscriptions {
  Subscriptions(entries: List(Entry))
}

type Entry {
  Entry(owner: String, uri: String)
}

pub fn new() -> Subscriptions {
  Subscriptions([])
}

/// Adds a resource subscription. Repeating an existing pair is idempotent.
pub fn subscribe(
  subscriptions: Subscriptions,
  owner: String,
  uri: ResourceUri,
) -> Subscriptions {
  let Subscriptions(entries) = subscriptions
  let uri = resource_uri_to_string(uri)
  case
    list.any(entries, fn(entry) { entry.owner == owner && entry.uri == uri })
  {
    True -> subscriptions
    False -> Subscriptions([Entry(owner, uri), ..entries])
  }
}

/// Removes one resource subscription. Unknown pairs are harmless.
pub fn unsubscribe(
  subscriptions: Subscriptions,
  owner: String,
  uri: ResourceUri,
) -> Subscriptions {
  let Subscriptions(entries) = subscriptions
  let uri = resource_uri_to_string(uri)
  Subscriptions(
    list.filter(entries, fn(entry) { entry.owner != owner || entry.uri != uri }),
  )
}

/// Removes every subscription owned by a disconnected peer.
pub fn close_owner(
  subscriptions: Subscriptions,
  owner: String,
) -> Subscriptions {
  let Subscriptions(entries) = subscriptions
  Subscriptions(list.filter(entries, fn(entry) { entry.owner != owner }))
}

pub fn is_subscribed(
  subscriptions: Subscriptions,
  owner: String,
  uri: ResourceUri,
) -> Bool {
  let Subscriptions(entries) = subscriptions
  let uri = resource_uri_to_string(uri)
  list.any(entries, fn(entry) { entry.owner == owner && entry.uri == uri })
}

/// Returns each peer once for a resource change.
pub fn owners_for_resource(
  subscriptions: Subscriptions,
  uri: ResourceUri,
) -> List(String) {
  let Subscriptions(entries) = subscriptions
  let uri = resource_uri_to_string(uri)
  list.fold(entries, [], fn(owners, entry) {
    case entry.uri == uri && !list.contains(owners, entry.owner) {
      True -> list.append(owners, [entry.owner])
      False -> owners
    }
  })
}

pub fn count(subscriptions: Subscriptions) -> Int {
  let Subscriptions(entries) = subscriptions
  list.length(entries)
}
