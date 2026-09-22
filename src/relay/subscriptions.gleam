import gleam/list
import relay/protocol/jsonrpc.{type RequestId}
import relay/resources.{type ResourceUri, resource_uri_to_string}

/// The set of notification types a client opts into via subscriptions/listen.
pub type SubscriptionFilter {
  SubscriptionFilter(
    tools_list_changed: Bool,
    resources_list_changed: Bool,
    prompts_list_changed: Bool,
    resource_subscriptions: List(String),
  )
}

pub fn empty_filter() -> SubscriptionFilter {
  SubscriptionFilter(
    tools_list_changed: False,
    resources_list_changed: False,
    prompts_list_changed: False,
    resource_subscriptions: [],
  )
}

/// Filters the requested notification types against the server's actual capabilities.
pub fn filter_supported(
  filter: SubscriptionFilter,
  has_tools: Bool,
  has_resources: Bool,
  has_prompts: Bool,
) -> SubscriptionFilter {
  SubscriptionFilter(
    tools_list_changed: filter.tools_list_changed && has_tools,
    resources_list_changed: filter.resources_list_changed && has_resources,
    prompts_list_changed: filter.prompts_list_changed && has_prompts,
    resource_subscriptions: case has_resources {
      True -> filter.resource_subscriptions
      False -> []
    },
  )
}

/// A subscription registry owned by one Relay server runtime.
pub opaque type Subscriptions {
  Subscriptions(entries: List(Entry))
}

type Entry {
  ResourceEntry(owner: String, uri: String)
  StreamEntry(owner: String, id: RequestId, filter: SubscriptionFilter)
}

pub fn new() -> Subscriptions {
  Subscriptions([])
}

/// Adds a modern subscription stream for a long-lived listen request.
pub fn listen(
  subscriptions: Subscriptions,
  owner: String,
  id: RequestId,
  filter: SubscriptionFilter,
) -> Subscriptions {
  let Subscriptions(entries) = subscriptions
  let filtered =
    list.filter(entries, fn(entry) {
      case entry {
        StreamEntry(o, stream_id, _) -> o != owner || stream_id != id
        _ -> True
      }
    })
  Subscriptions([StreamEntry(owner, id, filter), ..filtered])
}

/// Closes one specific subscription stream.
pub fn close_stream(
  subscriptions: Subscriptions,
  owner: String,
  id: RequestId,
) -> Subscriptions {
  let Subscriptions(entries) = subscriptions
  Subscriptions(
    list.filter(entries, fn(entry) {
      case entry {
        StreamEntry(o, stream_id, _) -> o != owner || stream_id != id
        _ -> True
      }
    }),
  )
}

/// Checks if a stream is active.
pub fn is_stream_active(
  subscriptions: Subscriptions,
  owner: String,
  id: RequestId,
) -> Bool {
  let Subscriptions(entries) = subscriptions
  list.any(entries, fn(entry) {
    case entry {
      StreamEntry(o, stream_id, _) -> o == owner && stream_id == id
      _ -> False
    }
  })
}

/// Returns all stream subscribers (owner and subscription request ID) that want updates for this resource URI.
pub fn stream_subscribers_for_resource(
  subscriptions: Subscriptions,
  uri: String,
) -> List(#(String, RequestId)) {
  let Subscriptions(entries) = subscriptions
  list.filter_map(entries, fn(entry) {
    case entry {
      StreamEntry(owner, id, filter) ->
        case list.contains(filter.resource_subscriptions, uri) {
          True -> Ok(#(owner, id))
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Returns all stream subscribers that want tools list changed notifications.
pub fn stream_subscribers_for_tools(
  subscriptions: Subscriptions,
) -> List(#(String, RequestId)) {
  let Subscriptions(entries) = subscriptions
  list.filter_map(entries, fn(entry) {
    case entry {
      StreamEntry(owner, id, filter) if filter.tools_list_changed ->
        Ok(#(owner, id))
      _ -> Error(Nil)
    }
  })
}

/// Returns all stream subscribers that want resources list changed notifications.
pub fn stream_subscribers_for_resources(
  subscriptions: Subscriptions,
) -> List(#(String, RequestId)) {
  let Subscriptions(entries) = subscriptions
  list.filter_map(entries, fn(entry) {
    case entry {
      StreamEntry(owner, id, filter) if filter.resources_list_changed ->
        Ok(#(owner, id))
      _ -> Error(Nil)
    }
  })
}

/// Returns all stream subscribers that want prompts list changed notifications.
pub fn stream_subscribers_for_prompts(
  subscriptions: Subscriptions,
) -> List(#(String, RequestId)) {
  let Subscriptions(entries) = subscriptions
  list.filter_map(entries, fn(entry) {
    case entry {
      StreamEntry(owner, id, filter) if filter.prompts_list_changed ->
        Ok(#(owner, id))
      _ -> Error(Nil)
    }
  })
}

/// Returns all active streams as #(owner, id).
pub fn all_streams(subscriptions: Subscriptions) -> List(#(String, RequestId)) {
  let Subscriptions(entries) = subscriptions
  list.filter_map(entries, fn(entry) {
    case entry {
      StreamEntry(owner, id, _) -> Ok(#(owner, id))
      _ -> Error(Nil)
    }
  })
}

/// Returns all stream IDs for a given owner.
pub fn streams_for_owner(
  subscriptions: Subscriptions,
  owner: String,
) -> List(RequestId) {
  let Subscriptions(entries) = subscriptions
  list.filter_map(entries, fn(entry) {
    case entry {
      StreamEntry(o, id, _) if o == owner -> Ok(id)
      _ -> Error(Nil)
    }
  })
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
    list.any(entries, fn(entry) {
      case entry {
        ResourceEntry(o, u) -> o == owner && u == uri
        _ -> False
      }
    })
  {
    True -> subscriptions
    False -> Subscriptions([ResourceEntry(owner, uri), ..entries])
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
    list.filter(entries, fn(entry) {
      case entry {
        ResourceEntry(o, u) -> o != owner || u != uri
        _ -> True
      }
    }),
  )
}

/// Removes every subscription and stream owned by a disconnected peer.
pub fn close_owner(
  subscriptions: Subscriptions,
  owner: String,
) -> Subscriptions {
  let Subscriptions(entries) = subscriptions
  Subscriptions(
    list.filter(entries, fn(entry) {
      case entry {
        ResourceEntry(o, _) -> o != owner
        StreamEntry(o, _, _) -> o != owner
      }
    }),
  )
}

pub fn is_subscribed(
  subscriptions: Subscriptions,
  owner: String,
  uri: ResourceUri,
) -> Bool {
  let Subscriptions(entries) = subscriptions
  let uri = resource_uri_to_string(uri)
  list.any(entries, fn(entry) {
    case entry {
      ResourceEntry(o, u) -> o == owner && u == uri
      _ -> False
    }
  })
}

/// Returns each peer once for a resource change.
pub fn owners_for_resource(
  subscriptions: Subscriptions,
  uri: ResourceUri,
) -> List(String) {
  let Subscriptions(entries) = subscriptions
  let uri = resource_uri_to_string(uri)
  list.fold(entries, [], fn(owners, entry) {
    case entry {
      ResourceEntry(owner, u) ->
        case u == uri && !list.contains(owners, owner) {
          True -> list.append(owners, [owner])
          False -> owners
        }
      _ -> owners
    }
  })
}

pub fn count(subscriptions: Subscriptions) -> Int {
  let Subscriptions(entries) = subscriptions
  list.length(entries)
}
