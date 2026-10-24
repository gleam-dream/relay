//// The listen streams one server runtime holds open, and the notification
//// filter each one asked for.

import gleam/list
import relay/internal/jsonrpc.{type RequestId}
import relay/subscriptions.{
  type Notification, PromptsListChanged, ResourceUpdated, ResourcesListChanged,
  ToolsListChanged,
}

/// The wire filter of a `subscriptions/listen` request.
pub type Filter {
  Filter(
    tools_list_changed: Bool,
    resources_list_changed: Bool,
    prompts_list_changed: Bool,
    resource_subscriptions: List(String),
  )
}

pub fn empty_filter() -> Filter {
  Filter(
    tools_list_changed: False,
    resources_list_changed: False,
    prompts_list_changed: False,
    resource_subscriptions: [],
  )
}

/// The filter a list of notifications asks for.
pub fn filter_of(notifications: List(Notification)) -> Filter {
  list.fold(notifications, empty_filter(), fn(filter, notification) {
    case notification {
      ToolsListChanged -> Filter(..filter, tools_list_changed: True)
      ResourcesListChanged -> Filter(..filter, resources_list_changed: True)
      PromptsListChanged -> Filter(..filter, prompts_list_changed: True)
      ResourceUpdated(uri) ->
        case list.contains(filter.resource_subscriptions, uri) {
          True -> filter
          False ->
            Filter(
              ..filter,
              resource_subscriptions: list.append(
                filter.resource_subscriptions,
                [uri],
              ),
            )
        }
    }
  })
}

/// The notifications a filter selects, in a stable order.
pub fn notifications_of(filter: Filter) -> List(Notification) {
  let kinds = case filter.tools_list_changed {
    True -> [ToolsListChanged]
    False -> []
  }
  let kinds = case filter.resources_list_changed {
    True -> list.append(kinds, [ResourcesListChanged])
    False -> kinds
  }
  let kinds = case filter.prompts_list_changed {
    True -> list.append(kinds, [PromptsListChanged])
    False -> kinds
  }
  list.append(kinds, list.map(filter.resource_subscriptions, ResourceUpdated))
}

/// Drops the kinds a server does not offer.
pub fn filter_supported(
  filter: Filter,
  has_tools: Bool,
  has_resources: Bool,
  has_prompts: Bool,
) -> Filter {
  Filter(
    tools_list_changed: filter.tools_list_changed && has_tools,
    resources_list_changed: filter.resources_list_changed && has_resources,
    prompts_list_changed: filter.prompts_list_changed && has_prompts,
    resource_subscriptions: case has_resources {
      True -> filter.resource_subscriptions
      False -> []
    },
  )
}

/// Whether a filter selects a notification.
pub fn selects(filter: Filter, notification: Notification) -> Bool {
  case notification {
    ToolsListChanged -> filter.tools_list_changed
    ResourcesListChanged -> filter.resources_list_changed
    PromptsListChanged -> filter.prompts_list_changed
    ResourceUpdated(uri) -> list.contains(filter.resource_subscriptions, uri)
  }
}

/// The open streams of one runtime.
pub opaque type Subscriptions {
  Subscriptions(entries: List(Entry))
}

type Entry {
  Entry(owner: String, id: RequestId, filter: Filter)
}

pub fn new() -> Subscriptions {
  Subscriptions([])
}

/// Opens a stream, replacing one with the same owner and id.
pub fn listen(
  subscriptions: Subscriptions,
  owner: String,
  id: RequestId,
  filter: Filter,
) -> Subscriptions {
  let Subscriptions(entries) = close_stream(subscriptions, owner, id)
  Subscriptions([Entry(owner, id, filter), ..entries])
}

/// Closes one stream.
pub fn close_stream(
  subscriptions: Subscriptions,
  owner: String,
  id: RequestId,
) -> Subscriptions {
  let Subscriptions(entries) = subscriptions
  Subscriptions(
    list.filter(entries, fn(entry) { entry.owner != owner || entry.id != id }),
  )
}

/// The streams, as owner and request id, that want a notification.
pub fn subscribers(
  subscriptions: Subscriptions,
  notification: Notification,
) -> List(#(String, RequestId)) {
  let Subscriptions(entries) = subscriptions
  list.filter_map(entries, fn(entry) {
    case selects(entry.filter, notification) {
      True -> Ok(#(entry.owner, entry.id))
      False -> Error(Nil)
    }
  })
}

/// The number of open streams.
pub fn count(subscriptions: Subscriptions) -> Int {
  let Subscriptions(entries) = subscriptions
  list.length(entries)
}
