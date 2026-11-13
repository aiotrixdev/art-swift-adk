# ART Swift ADK

![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%2015%2B%20%7C%20macOS%2013%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)

The ART Swift ADK connects iOS and macOS apps to [ART (A Realtime Tech)](https://arealtimetech.com/), a realtime communication platform for building intelligent applications with WebSocket-based messaging, AI Agents, AI Orchestrators, presence tracking, end-to-end encrypted channels, and CRDT-backed shared objects.

With the ADK you can:

- Send and receive messages in real time
- See who is online in a channel
- Encrypt conversations end-to-end
- Keep shared data in sync across users and devices
- Check or block messages before they are delivered
- Chat with AI agents and run multi-agent workflows
- Upload files and share them with AI agents
- Receive in-app notifications

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Connection](#connection)
- [Channels and messages](#channels-and-messages)
- [Presence](#presence)
- [Encrypted channels](#encrypted-channels)
- [Shared objects](#shared-objects)
- [Interceptors](#interceptors)
- [AI agents](#ai-agents)
- [AI orchestrators](#ai-orchestrators)
- [File storage](#file-storage)
- [Profiles and connectors](#profiles-and-connectors)
- [Notifications](#notifications)
- [Calling ART APIs](#calling-art-apis)
- [Errors](#errors)
- [Logging](#logging)
- [Documentation](#documentation)
- [License](#license)

## Requirements

- iOS 15 or later, or macOS 13 or later
- Xcode 15 or later (Swift 5.9)
- An ART project with its environment, project key, organisation and client ID

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aiotrixdev/art-swift-adk.git", from: "1.0.3")
]
```

Then add the required libraries to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "ArtAdk", package: "art-swift-adk"),
        .product(name: "ArtAdkNotifications", package: "art-swift-adk") // optional
    ]
)
```

### Xcode

1. Choose **File › Add Package Dependencies…**
2. Enter `https://github.com/aiotrixdev/art-swift-adk.git`.
3. Add **ArtAdk** to your app target. Add **ArtAdkNotifications** only if your app uses notifications.

## Getting started

### 1. Get a user passcode

ART signs users in with a short-lived passcode. Your backend requests the passcode from ART using your client secret, and returns only the passcode to the app:

```swift
func fetchPasscode(for username: String) async throws -> String {
    var request = URLRequest(url: URL(string: "PASSCODE_URL")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username])

    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json?["passcode"] as? String ?? ""
}
```

> **Important:** Never put your client secret in the app. Anything shipped inside an app can be extracted. Whether users can sign in using only a passcode depends on your ART project settings, so confirm this with the ART team before release.

### 2. Create credentials and connect

```swift
import ArtAdk

let passcode = try await fetchPasscode(for: "john_doe")

let adk = Adk(config: AdkConfig(uri: "YOUR_WEBSOCKET_URI", authToken: passcode))

adk.setCredentials(CredentialStore(
    environment: "YOUR_ENV",
    projectKey:  "YOUR_PROJECT_KEY",
    orgTitle:    "YOUR_ORG",
    clientID:    "YOUR_CLIENT_ID",
    accessToken: passcode
))

try await adk.connect()
```

### 3. Send and receive a message

```swift
let channel = try await adk.subscribe(channel: "CHANNEL_NAME")

channel.emitter.on("message") { data in
    print("Received:", data)
}

try await channel.push(event: "message", data: ["text": "Hello ART!"])
```

### Other ways to provide credentials

`setCredentials(_:)` is the simplest option. You can also use one of these:

| **Option** | **When to use it** |
|---|---|
| `AdkConfig(getCredentials: { … })` | Your credentials change over time, for example when the passcode is refreshed. The ADK calls the closure each time it signs in. |
| `AdkConfig(autoLoadCredsFromJSON: true)` | You keep credentials in an `adk-services.json` file, either in the app bundle or in the folder set with `AdkConfig(root:)`. The file uses the keys `Client-ID`, `Environment`, `Org-Title` and `ProjectKey`. |

If you use more than one option, `getCredentials` takes priority. Otherwise the ADK uses `setCredentials(_:)`, unless `autoLoadCredsFromJSON` is `true`: then the JSON file replaces those credentials when it can be read. The ADK also reads the file when you haven't set any credentials.

When you provide both a client ID and a client secret, the ADK signs in with them and signs in again whenever the access token needs renewing. Otherwise it exchanges `accessToken` for an ART token and renews it with a refresh token.

## Connection

`connect()` opens the connection, signs the user in, and returns once ART has accepted the connection. If the connection drops, the ADK reconnects automatically.

```swift
adk.on("connection") { data in
    if let connection = data as? ConnectionDetail {
        print("Connected:", connection.connectionId)
    }
}

adk.on("close") { reason in
    print("Connection closed, reconnecting:", reason)
}

do {
    try await adk.connect()
} catch let error as ConnectionError {
    print("Couldn't connect:", error.code, error.message)
}
```

`connect()` throws a `ConnectionError` when it can't connect: `AUTHENTICATION_FAILED` when the credentials are missing or ART rejects them, or `CONNECTION_TIMEOUT` when the connection isn't ready in time. Calls made while a connection attempt is in progress share it.

By default the ADK waits up to 30 seconds for the connection, for a sign-in request and for ART's reply to a request such as a subscribe. To change this, set `connectionTimeoutMs` to a positive number; anything else makes `connect()` throw `ARTError.invalidArgument`. It doesn't limit how long an agent can take to answer.

```swift
let adk = Adk(config: AdkConfig(uri: "YOUR_WEBSOCKET_URI", connectionTimeoutMs: 15_000))
```

You can pause the connection and resume it later. A paused connection stays closed until you call `resume()`.

```swift
adk.pause()
try await adk.resume()

await adk.disconnect()   // close the connection
```

### When the connection fails

Sometimes the connection can't continue: the credentials were rejected, a limit was reached, you paused or closed the connection, or it couldn't be restored after five attempts. The ADK then emits `connectionFailed` with a `ConnectionError` and stops reconnecting. Agent runs in progress end with an error, and later sends and subscribes throw the same `ConnectionError` until you call `connect()` again.

```swift
adk.on("connectionFailed") { data in
    if let error = data as? ConnectionError {
        print("Connection failed:", error.code, error.message)
    }
}

adk.on("authenticationFailed") { data in
    if let detail = data as? AuthenticationFailedDetail {
        print("Sign-in rejected:", detail.status, detail.error)   // update the credentials, then connect() again
    }
}
```

| **Code** | **Meaning** |
|---|---|
| `AUTHENTICATION_FAILED` | The credentials are missing or were rejected. `status` holds the HTTP status when ART rejected them. |
| `CONNECTION_TIMEOUT` | The connection, or ART's reply to a request, didn't arrive in time |
| `CONNECTION_LOST` | The connection dropped before a message could be sent, or couldn't be restored |
| `CONNECTION_PAUSED`, `CONNECTION_CLOSED` | You called `pause()`, `closeWebSocket()` or `disconnect()` |
| `CONNECTION_CANCELLED` | A newer connection attempt replaced this one |
| `CONNECTION_AUTHORIZATION_FAILED` | The connection's sign-in couldn't be renewed |
| `ACK_TIMEOUT` | ART didn't confirm a message |
| `CONNECTION_MINUTES_LIMIT_EXCEEDED`, `CONCURRENT_LIMIT_EXCEEDED` | Your project reached its billing or concurrency limit |

`adk.state` tells you where the connection stands:

| **State** | **Meaning** |
|---|---|
| `.connecting` | Opening the connection, or reconnecting after it dropped |
| `.connected` | Connected and signed in |
| `.paused` | Paused with `pause()` |
| `.stopped` | Not connected |

If your project reaches its billing or concurrency limit, the ADK also emits a `limitExceeded` event.

## Channels and messages

A channel is a named stream of messages. Subscribe to a channel to send and receive messages on it. `subscribe` returns a `Subscription` for regular channels and a `LiveObjSubscription` for [shared-object channels](#shared-objects).

```swift
let channel = try await adk.subscribe(channel: "room-42")

// When you no longer need the channel:
await channel.unsubscribe()
```

### Sending messages

```swift
try await channel.push(event: "message", data: ["text": "Hello"])
```

To send a message to specific users, list their usernames in the `to` option:

```swift
try await channel.push(
    event: "message",
    data: ["text": "Hi Bob"],
    options: PushConfig(to: ["bob"])
)
```

On targeted and encrypted channels, `push` waits until ART confirms delivery. If no confirmation arrives within 50 seconds, it throws a `ConnectionError` with the code `ACK_TIMEOUT`.

The ADK never queues a message to send later. If there's no connection, `push` throws a `ConnectionError` and the message isn't sent. A message is never resent automatically, so after an error, check whether it took effect before you send it again.

### Receiving messages

```swift
channel.emitter.on("message") { data in
    print("Received:", data)
}
```

On regular channels, `bind(event:)` also delivers messages that arrived before you started listening. It returns a token that you can use to remove that listener later:

```swift
if let subscription = channel as? Subscription {
    let token = subscription.bind(event: "message") { content in
        print(content)
    }

    // Later:
    subscription.remove(event: "message", id: token)
}
```

## Presence

Find out who is online in the channel. The callback runs again whenever someone joins or leaves.

```swift
let stopPresence = try await channel.fetchPresence { users in
    print("Online:", users)
}

// Later, to stop receiving updates:
try await stopPresence()
```

## Encrypted channels

Messages on encrypted channels are encrypted on the sender's device, and only the recipients can read them. Before using an encrypted channel, create a key pair for the current user. `generateKeyPair()` creates the keys and registers the public key with ART.

```swift
_ = try await adk.generateKeyPair()

let secure = try await adk.subscribe(channel: "SECURE_CHANNEL")

secure.emitter.on("message") { data in
    print("Decrypted:", data)
}

try await secure.push(
    event: "message",
    data: ["text": "Private"],
    options: PushConfig(to: ["bob"])
)
```

## Shared objects

A shared-object channel holds a document that every subscriber can read and edit. Changes are merged automatically using CRDTs (conflict-free replicated data types), so everyone ends up with the same data.

```swift
let channel = try await adk.subscribe(channel: "CRDT_CHANNEL")

if let live = channel as? LiveObjSubscription {
    // Edit the document, then send your changes.
    live.state()["document"]["title"].set("My Doc")
    await live.flush()
    // Read a value.
    if let document = await live.query(path: "document").execute() {
        print(document)
    }

    // Watch for changes. The callback also receives the current value.
    let stopWatching = await live.query(path: "document").listen { value in
        print("Updated:", value)
    }

    // Later:
    stopWatching()
}
```

Lists support the usual operations:

```swift
let items = live.state()["items"]

items.push("alpha")                                     // add to the end
items.unshift("zero")                                   // add to the start
items.pop()                                             // remove the last item
items.removeAt(2)                                       // remove the item at an index
items.splice(start: 1, deleteCount: 1, insert: ["x"])   // replace a range

await live.flush()
```

## Interceptors

An interceptor sees messages before they are delivered and decides what happens to each one. Call `resolve` to deliver the message, with or without changes, or `reject` to block it.

```swift
_ = try await adk.intercept(interceptor: "profanity-filter") { payload, resolve, reject in
    if let text = payload["text"] as? String, text.contains("badword") {
        reject("Message blocked")
        return
    }
    resolve(payload)
}
```

The name must match an interceptor set up in your ART project.

## AI agents

Chat with an agent built on ART. Each conversation takes place in a thread.

### Start a conversation

```swift
let agent = try adk.agent("your-agent-id")
let thread = agent.thread()   // or agent.thread("THREAD_ID") to continue a conversation

try await thread.listen { envelope in
    print("Event:", envelope.event)
}

let run = try await thread.run("Plan a 3-day trip to Dubai")

do {
    let output = try await run.done()
    print(output.message)
} catch let error as AgentError {
    print("The agent couldn't finish:", error.message)
}
```

`run.done()` waits for the agent's final answer. `listen` receives every event in the thread as it happens, such as progress updates and questions from the agent. `envelope.content` holds all the fields the server sent with the event.

An agent ID is the agent's slug, such as `travel-agent`. To use a specific build, add its name: `travel-agent@release2`. Any other ID throws `ARTError.invalidArgument`.

`listen`, `listenState` and `run` subscribe to the agent's channel when needed, and throw if that fails. For example, they throw `ARTError.serverError` with the server's message when the signed-in user has no access to the agent. A callback whose `listen` failed isn't kept, so call `listen` again once the cause is fixed.

If the connection fails during a run, the run ends with an `AgentError` that has the connection error's code, and `details["source"]` is `"connection"`. The agent may still finish on the server, but the app can't receive the answer, so check the result before you run the request again. The thread's state becomes `failed` with the message "Connection unavailable".

```swift
do {
    let output = try await run.done()
    print(output.message)
} catch let error as AgentError where error.details?["source"] as? String == "connection" {
    print("Connection lost:", error.code)
}
```

When you no longer need a thread, call `thread.dispose()`. It ends the thread's run and removes the thread's listeners, while other threads of the agent keep working. After `dispose()`, `run`, `listen` and `listenState` throw an error.

Runs started from the ART playground can say so with `thread.run(input, executionOrigin: .playground)`.

### Display progress

Use the thread's state to drive a status indicator, such as "Queued" or "Waiting for your input":

```swift
let stopUpdates = try await thread.listenState { state in
    print(state.phase, state.message)
}

print(thread.getState().phase)   // the latest state
stopUpdates()                    // stop receiving updates
```

The phase is one of `idle`, `submitted`, `queued`, `running`, `waitingForAgent`, `waitingForApproval`, `waitingForWorkspace`, `completed`, `failed` or `cancelled`.

### Answer questions from the agent

An agent can pause and ask the user for more information. This is often called human-in-the-loop. Register a handler before you start the run, and send the answer with `sendFeedback`:

```swift
thread.feedbackRequest { request, run in
    print("The agent asks:", request.prompt)

    Task {
        do {
            try await run.sendFeedback("Budget is 50,000, travelling in December")
        } catch {
            print("Couldn't send the answer:", error)
        }
    }
}
```

### Share files with an agent

Upload the file to the thread first, then attach it to your message:

```swift
let file = try await thread.upload(fileURL: documentURL, options: UploadOptions(
    progress: { fraction in print("Uploaded \(Int(fraction * 100))%") }
))

let run = try await thread.run("Summarize this document", fileMeta: [MediaRef(file)])
```

The file belongs to the thread and is owned by the agent. `thread.listFiles()` lists the thread's files.

## AI orchestrators

An orchestrator coordinates several agents to complete a larger task. Start a thread, listen for its events, and send the user's input:

```swift
let orchestrator = try adk.orchestrator("your-orchestrator-id")
let thread = try await orchestrator.thread()

thread.listen { event in
    print(event)
}

thread.listenState { state in
    print(state.phase)
}

try await thread.push(event: "user_input", data: ["message": "Plan a 3-day trip to Goa"])
```

If the connection fails while a request is in progress, `listen` receives an `agent_error` event whose details have `source: connection`, and the thread's state becomes `failed`. Call `thread.dispose()` when you no longer need the thread.

## File storage

Files are temporary media that belong to a conversation thread. Upload a file, then list, fetch or delete it. Each upload returns a `FileRef` with the file's ID, name, size, content type and a URL for reading it. `listFiles` leaves out that URL, and `getFile` includes it.

The easiest way is to upload from an agent or orchestrator thread, which fills in the thread for you (see [Share files with an agent](#share-files-with-an-agent)). When you use `adk` directly, pass the thread ID:

```swift
let ref = try await adk.upload(
    data: pngData, filename: "chart.png", contentType: "image/png",
    options: UploadOptions(threadId: "THREAD_ID", allowedMimeTypes: ["image/png"])
)

let page = try await adk.listFiles(options: ListOptions(threadId: "THREAD_ID", page: 1, limit: 20))
let file = try await adk.getFile(fileId: ref.fileId, threadId: "THREAD_ID")   // includes a URL for reading the file
try await adk.deleteFile(fileId: ref.fileId)
```

To upload a file from disk, use `upload(fileURL:)`. The file is streamed rather than loaded into memory, and you can follow its progress with `UploadOptions(progress:)`: it reports `0` when the upload starts and `1` once ART has stored the file. Set `ttlSeconds` to choose how long the file is kept, and `allowedMimeTypes` to limit the types ART accepts. To cancel an upload, cancel the task that runs it.

Every file has an owner, which depends on where you upload it from:

| **Uploaded with** | **Owner** |
|---|---|
| `adk.upload` | Your project, or the configuration you pass in `UploadOptions(configId:)` |
| `agent.upload`, or `upload` on an agent thread | The agent |
| `orchestrator.upload`, or `upload` on an orchestrator thread | The orchestrator |
| `upload` on a channel | The channel's configuration (orchestrator-enabled channels only) |

When an upload fails, the ADK throws an `UploadError`. Its `step` tells you which stage failed (`.validate`, `.upload`, `.list`, `.get` or `.delete`), and `status` holds the HTTP status code. A `403` means the user's role doesn't have storage permission.

```swift
do {
    _ = try await adk.upload(data: pngData, options: UploadOptions(threadId: "THREAD_ID"))
} catch let error as UploadError where error.step == .upload && error.status == 403 {
    print("This user's role doesn't allow uploads")
}
```

## Profiles and connectors

Update the signed-in user's profile. Only the fields you set are changed.

```swift
try await adk.updateProfile(UpdateProfileData(firstName: "Ada", email: "ada@example.com"))
```

Each connector keeps its own profile for the user. Read it, or update the fields that the connector allows:

```swift
let crm = try adk.connector("YOUR_CONNECTOR_ID")

let profile = try await crm.profile()          // the allowed fields and their current values
try await crm.updateProfile(["region": "eu"])  // only allowed fields can be changed
```

## Notifications

Notifications are in the optional `ArtAdkNotifications` library. Add it to your `Adk` instance once and keep the object it returns:

```swift
import ArtAdkNotifications

let inbox = adk.use(notifications())

// Receive new notifications as they arrive.
let stopListening = try await inbox.onNew { notification in
    print(notification.title)
}

let unread = try await inbox.list(NotificationListParams(status: .unread))
try await inbox.markRead()   // marks every unread notification as read
```

You can also send notifications and count unread notifications. A notification you send is delivered in-app unless you set `channels` on `SendNotificationInput` to `.inApp`, `.email` or both. To get the same object elsewhere in your app, call `adk.plugin("notifications", as: NotificationsApi.self)`.

## Calling ART APIs

`call` sends an authenticated request to an ART REST endpoint and returns the decoded JSON response:

```swift
let result: [String: Any] = try await adk.call(
    endpoint: "/v1/some-endpoint",
    options: CallApiProps(method: "POST", payload: ["key": "value"])
)
```

To send a `multipart/form-data` request, pass a `FormDataPayload` as the payload:

```swift
let response: [String: Any] = try await adk.call(
    endpoint: "/v1/some-upload",
    options: CallApiProps(method: "POST", payload: FormDataPayload(
        fields: ["purpose": "avatar"],
        files: [FormDataFile(field: "file", data: pngData, filename: "avatar.png", contentType: "image/png")]
    ))
)
```

## Errors

| **Error** | **Thrown when** |
|---|---|
| `ConnectionError` | The connection failed or isn't available. See [When the connection fails](#when-the-connection-fails). |
| `AuthHttpError` | ART rejected a sign-in request. `status` holds the HTTP status, and `isTerminal` is `true` for rejected credentials (401 or 403). |
| `AgentError` | An agent run failed, or ended because the connection failed |
| `RunLifecycleError` | `run.done()` ended without an answer from the agent, because a newer run on the thread replaced it (`.superseded`) or its thread was disposed (`.closed`). `sendFeedback` also throws `.closed` when the agent isn't waiting for an answer. |
| `UploadError` | A storage request failed |
| `ConnectorError` | A connector ID is empty or can't be resolved, or you updated a field the connector doesn't allow |
| `HTTPCallError` | An ART REST request failed in `updateProfile` or a plugin |
| `ArtJSONError` | Data you passed can't be converted to JSON |
| `ARTError` | Other errors, for example `.invalidArgument` for an agent ID that isn't a slug, or `.serverError` when ART refuses a request or `adk.call` gets an error response |

## Logging

The ADK doesn't print anything by default. To see its warnings and errors, set a log handler:

```swift
ArtLog.handler = { level, message in
    print("[ART][\(level)] \(message)")
}
```

## Documentation

For full guides, see the [ART ADK documentation](https://docs.arealtimetech.com/docs/adk/). For what's new in each release and how to upgrade, see the [changelog](https://github.com/aiotrixdev/art-swift-adk/blob/main/CHANGELOG.md).

| **Topic** | **Link** |
|---|---|
| Overview | [ADK overview](https://docs.arealtimetech.com/docs/adk/) |
| Installation | [Swift installation](https://docs.arealtimetech.com/docs/adk/swift/installation) |
| Publish and subscribe | [Pub/sub](https://docs.arealtimetech.com/docs/adk/swift/pub-sub) |
| Connection management | [Connections](https://docs.arealtimetech.com/docs/adk/swift/connection-management) |
| User presence | [Presence](https://docs.arealtimetech.com/docs/adk/swift/user-presence) |
| Encrypted channels | [Encryption](https://docs.arealtimetech.com/docs/adk/swift/encrypted-channel) |
| Shared object channels | [Shared objects](https://docs.arealtimetech.com/docs/adk/swift/shared-object-channel) |
| Interceptors | [Interceptors](https://docs.arealtimetech.com/docs/adk/swift/intercept-channel) |
| Agents | [Agents](https://docs.arealtimetech.com/docs/adk/swift/agent) |
| Orchestrators | [Orchestrators](https://docs.arealtimetech.com/docs/adk/swift/orchestrator) |

## License

The ART Swift ADK is released under the [MIT License](https://github.com/aiotrixdev/art-swift-adk/blob/main/LICENSE).
