//// The notifications a `subscriptions/listen` stream delivers.
////
//// A server sends a `Notification` with `relay/http.notify`,
//// `relay/runtime.notify` or the reducer; a client asks for the same values
//// with `relay/client.listen` and receives them from
//// `relay/client.next_notification`. A server confirms only the kinds it
//// offers: a server without resources drops the resource kinds.
////
//// ```gleam
//// import relay/subscriptions.{ResourceUpdated, ToolsListChanged}
////
//// pub fn interests() -> List(subscriptions.Notification) {
////   [ToolsListChanged, ResourceUpdated("file:///notes.txt")]
//// }
//// ```

/// A change a listening client is told about. `ResourceUpdated` names one
/// resource URI; in a `listen` request it subscribes to that resource.
pub type Notification {
  ToolsListChanged
  ResourcesListChanged
  PromptsListChanged
  ResourceUpdated(uri: String)
}
