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
