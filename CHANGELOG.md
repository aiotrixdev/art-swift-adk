# Changelog

All notable changes to the ART Swift ADK are documented in this file.

## [1.0.2]

### Added

- **File storage.** Upload, list, fetch and delete files. A file can belong to your project, an agent, an orchestrator, a conversation thread or a channel. Uploads from disk are streamed and report their progress. If an upload fails, the error tells you which step failed and includes the HTTP status code.
- **Files for AI agents.** Attach uploaded files to a message with `thread.run(_:fileMeta:)` so the agent can use them. Channel messages can carry files too, through `PushConfig(fileMeta:)`.
- **Conversation status.** Agent and orchestrator threads report their current status, such as queued, running, waiting for input, completed or failed. Follow it with `listenState` or read it with `getState()`.
- **Complete event data.** Agent events include every field the server sent, in `AgentEventEnvelope.content`.
- **Profiles.** Update the signed-in user's profile with `updateProfile(_:)`, and read or update the user's profile for a connector with `connector(_:)`.
- **Notifications.** The new, optional `ArtAdkNotifications` library receives notifications as they arrive, lists past notifications, marks them as read, sends notifications and registers devices for push notifications.
- **More ways to provide credentials.** Pass credentials with `setCredentials(_:)`, or load them automatically from `adk-services.json` with `AdkConfig(autoLoadCredsFromJSON:)`.
- **REST call options.** `CallApiProps` accepts a custom base URL and a timeout.
- **Removing a single listener.** On regular channels, `bind`, `listen`, `attachThreadListener` and `attachThreadBind` return a token. Pass it to `remove(event:id:)` or `detachThreadListener(_:_:id:)` to remove that listener without affecting the others.

### Changed

- On targeted channels, `push` now waits until ART confirms delivery. If no confirmation arrives within 50 seconds, it throws `ARTError.ackTimeout`.
- Messages on a channel are delivered to your listeners one at a time, in the order they arrive.
- `Adk.state` reports `.connected` only after the server has accepted the connection, and `.connecting` while the ADK reconnects.
- Access tokens are renewed 30 seconds before they expire, and requests made at the same time share a single renewal.
- Agent threads include their thread ID in every message, and also receive replies addressed to that thread. New thread IDs are lowercase UUIDs.
- Answers sent through the `reply` closure of a request for human input are encoded as JSON, so text answers arrive in quotes.
- An interceptor that resolves with an array now sends the array unchanged.
- `adk-services.json` is now loaded from the app bundle.
- The `art_notifications` channel is now subscribed on the server. It's a broadcast channel, so notifications sent to subscribers now reach `onNew`.

### Fixed

- Agent responses were empty when the server sent their content as JSON text. The message, reference ID and question text are now read correctly.
- `pause()` reconnected automatically after five seconds. The connection now stays paused until you call `resume()`.
- `Subscription.thread()` always failed on orchestrator-enabled channels.
- Apps couldn't call the `reply` closure attached to a request for human input.
- Presence updates on shared-object channels never reached `fetchPresence`.
- Shared-object channels applied changes from messages other than updates.
- Closing one orchestrator thread removed the trace listeners of other threads.
- Data that can't be converted to JSON crashed the app. The ADK now throws `ArtJSONError` instead.

### Deprecated

- `listenTrace` on agent and orchestrator threads. Use `listenState` for status updates.

### Upgrading

- If you `switch` over `AgentEvent`, handle the new `.threadState` case or add a `default` case.
- `push` on targeted channels now waits for delivery confirmation. Don't block the UI while it waits, and handle `ARTError.ackTimeout`.

## [1.0.1]

### Added

- AI agent support
  - Agent API
  - Agent threads (`AgentThread`)
  - Run lifecycle
  - Typed agent events
  - Human-in-the-loop (HITL) support
  - Agent trace listeners
- AI orchestrator support
  - Orchestrator API
  - Orchestrator threads (`OrchestratorThread`)
  - Thread-scoped workflow communication
  - Human-in-the-loop (HITL) replies
  - Workflow trace listeners

### Changed

- Added documentation for agents and orchestrators.
- Added AI workflow examples to the README.
- Added an Agent Tester to the SwiftUI example app.
- Improved the package documentation for the Swift Package Index.

## [1.0.0]

Initial release.

### Added

- WebSocket connection management
- Channel subscriptions: broadcast, targeted, group, encrypted and shared
- Sending messages
- Listening for events
- User presence
- Encrypted channels
- Interceptors for processing messages
- Shared object channels, backed by CRDTs

[1.0.2]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.2
[1.0.1]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.1
[1.0.0]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.0
