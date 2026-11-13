# Changelog

All notable changes to the ART Swift ADK are documented in this file.

## [1.0.3]

### Added

- **Connection failures you can handle.** The new `connectionFailed` event delivers a `ConnectionError` with a readable `message`, a `code` and the HTTP `status` when there is one. It fires when the credentials are missing or rejected, a token can't be renewed, a billing or concurrency limit is reached, the connection isn't ready in time, it can't be restored after five reconnect attempts, or the app pauses or closes it. The ADK then stops reconnecting until you call `connect()` again.
- **Agent runs end when the connection fails.** The active run ends with an `AgentError` that has the connection error's code, and its details have `source: connection` and `execution_status: unknown`, because the app can no longer tell whether the agent finished. The thread's state becomes `failed` with the message "Connection unavailable". Orchestrator threads with a request in progress report the same through `listen`.
- **`AdkConfig.connectionTimeoutMs`** (default 30 seconds) sets how long the ADK waits for the connection to be ready, for a sign-in request and for ART's reply to a request such as a subscribe. It doesn't limit how long an agent can take to answer.
- **Rejected credentials stop reconnecting.** The new `authenticationFailed` event (`AuthenticationFailedDetail`) fires when ART rejects the credentials, or when renewing a token fails while reconnecting. Sign-in rejections throw `AuthHttpError` with the HTTP `status`; `isTerminal` (and `isTerminalAuthError(_:)`) is `true` for HTTP 401 and 403.
- **`AgentThread.dispose()`** ends the thread's run, so `run.done()` throws `RunLifecycleError.closed`, and removes only that thread's listeners. Other threads of the agent keep working. `isDisposed` tells you whether it was called.
- **Execution origin.** `thread.run(_:executionOrigin:)` and `PushConfig(executionOrigin:)` mark requests started from the ART playground (`execution_origin`). Replies keep the origin of the thread's latest run.
- **Multipart requests.** `CallApiProps.payload` accepts a `FormDataPayload` for `multipart/form-data` requests.
- `Subscription.configurationId` and `ChannelConfig.configurationID`: the server-side configuration behind a channel.
- `validateExecutionReference(_:)` checks an agent or orchestrator ID.
- `ARTError.message`: the error's text without the prefix that `errorDescription` adds.

### Changed

- `connect()` returns once ART has accepted the connection, and throws the `ConnectionError` when it can't connect, for example `AUTHENTICATION_FAILED` for missing or rejected credentials or `CONNECTION_TIMEOUT`. Calls made while an attempt is in progress share it. `resume()` now calls `connect()` and throws too.
- `pause()`, `closeWebSocket()` and `disconnect()` end the connection with `CONNECTION_PAUSED` or `CONNECTION_CLOSED`, so runs in progress end with an error. `disconnect()` also removes the instance's own listeners from the connection; `connect()` adds them back.
- Messages are never queued to be sent later. Without a connection, `push` and `run` throw a `ConnectionError` (`CONNECTION_LOST`) and the message isn't sent; a message is never resent automatically.
- Encrypted channels now wait for ART to confirm delivery, like targeted channels. A missing confirmation throws a `ConnectionError` with the code `ACK_TIMEOUT` instead of `ARTError.ackTimeout`.
- After five failed reconnect attempts, the connection fails with `CONNECTION_LOST` instead of retrying forever.
- Requests to ART's `art_secure` line, such as subscribes, throw `CONNECTION_TIMEOUT` when no reply arrives in time. `subscribe()` on a subscription now throws when it fails.
- With a client ID and client secret, the ADK signs in again to renew the access token and never uses refresh tokens. Without a client secret it exchanges `accessToken` and renews it with the refresh token, as before. A sign-in sends either the client credentials or the access token, not both.
- Sign-in requests give up after `connectionTimeoutMs`, and a response without an access token is an error.
- When the access token changes, the connection's sign-in is renewed with ART before the next push or subscribe.
- `Auth.getInstance(credentials:)` updates the stored credentials, and starts with an empty token cache when the organisation, environment, project or client ID changes. A `getCredentials` closure that switches to another identity also drops the old tokens.
- The long-poll fallback stops when ART rejects the credentials, and reports failed polls as `AuthHttpError`. Its connection becomes active once a poll is answered, so `connect()` fails with `CONNECTION_TIMEOUT` when ART can't be reached.
- **Files are temporary media that belong to a conversation thread.** `UploadOptions.threadId` and `ListOptions.threadId` are required, and `getFile` takes a `threadId`. Uploads from agents, orchestrators, their threads and channels are owned by the channel's server-side configuration. Files in `listFiles` have no `readUrl`; `getFile` returns one.
- New `UploadOptions.allowedMimeTypes`. Upload progress reports `0` when the upload starts and `1` once ART has stored the file.
- `UploadError.step` is now `.validate`, `.upload`, `.list`, `.get` or `.delete`.
- Files attached to a message are `MediaRef` values (`id`, `name`, `content_type`). Create one with `MediaRef(fileRef)`.
- Agent and orchestrator IDs must be lowercase slugs, optionally with a build name (`my-agent@release2`). `adk.agent(_:)`, `adk.orchestrator(_:)` and the `Agent` and `Orchestrator` initialisers throw `ARTError.invalidArgument` for anything else.
- `IWebsocketHandler` has new requirements: `ensureAuthorization()`, `onConnectionFailure(_:)` and `offConnectionFailure(_:)`. `wait()` and `sendMessage(_:)` now throw, and so does `Socket.initiateSocket(credentials:)`.
- `AgentThread.listen`, `listenState` and `listenTrace` now throw when subscribing to the agent's channel fails, for example when ART refuses access to the agent, and after `dispose()`. A callback whose call failed isn't kept, so call again to retry.
- The `open` event now fires when the WebSocket has actually opened. If it can't open, the ADK tries server-sent events before giving up. The wait for the WebSocket is limited by `connectionTimeoutMs`.
- On the server-sent events fallback, a stream that ends counts as a dropped connection and reconnects, and a failed stream fires `error`. Only unnamed events are treated as messages, and a `close` event from ART ends the connection without reconnecting.
- `fetchPresence` no longer waits for ART to confirm the presence request on targeted and encrypted channels.
- A subscribe reply without a channel configuration throws `ARTError.serverError` instead of `ARTError.channelNotFound`.
- `SendNotificationInput.channels` is now a list of `NotificationChannel` values: `.inApp` or `.email`. Push is no longer a delivery channel.

### Fixed

- `thread.run` no longer continues without its listeners when subscribing fails the first time and succeeds on the internal retry, which left `done()` waiting forever. It now throws the error and sends nothing.
- The heartbeat's `timestamp` is a whole number of milliseconds.

### Deprecated

- `FileMeta`: use `MediaRef`.
- `UploadOptions.scopes`: access follows the owning configuration and the thread, so scopes are ignored.
- `ConfigType.knowledgeBase`: storage only holds media files.
- The `UploadStep` cases `.signedURL`, `.put` and `.confirm`: an upload is now a single request (`.upload`).

### Removed

- **Push-device registration.** `registerDevice`, `unregisterDevice`, `listDevices`, `RegisterDeviceInput`, `PushDevice`, `PushDeviceList` and `DevicePlatform` are gone, because ART no longer offers these APIs.

### Upgrading

- Write `try await adk.connect()` and `try await adk.resume()`, and handle the `ConnectionError`.
- Write `try adk.agent(...)` and `try adk.orchestrator(...)`, and make sure the IDs are slugs.
- Write `try await thread.listen { ... }` and `try await thread.listenState { ... }` on agent threads, and handle the error. It tells you why the channel can't be used.
- Write `try await channel.subscribe()` where you call it directly.
- Pass a thread ID when you use storage directly: `UploadOptions(threadId:)`, `ListOptions(threadId:)` and `getFile(fileId:threadId:)`. Thread `upload` and `listFiles` set it for you.
- Replace `FileMeta(file)` with `MediaRef(file)`. `FileMeta(id:scope:)` and `scope` are gone: use `MediaRef(id:name:contentType:)`, because access now follows the owning configuration and the thread. Handle `UploadError.step == .upload` where you checked `.signedURL`, `.put` or `.confirm`.
- Catch `ConnectionError` with the code `ACK_TIMEOUT` where you caught `ARTError.ackTimeout`.
- If you `switch` over `ARTError`, handle the new `.invalidArgument` case or add a `default` case.
- If you implement `IWebsocketHandler` or call `wait()` or `sendMessage(_:)` on the socket yourself, add the new requirements and handle the errors.
- Listen for `connectionFailed` to show that the connection is gone and offer a way to reconnect.
- Remove calls to `registerDevice`, `unregisterDevice` and `listDevices`, and use a notifier configured on a connector instead.
- Replace channel strings with `NotificationChannel` values, for example `channels: [.inApp, .email]`.

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

[1.0.3]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.3
[1.0.2]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.2
[1.0.1]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.1
[1.0.0]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.0
