# ART Swift SDK

Swift SDK for **[ART — A Realtime Tech communication,](https://arealtimetech.com/)**, a realtime messaging platform providing WebSocket-based channels, presence tracking, end-to-end encrypted messaging, and CRDT-backed shared objects.


## Features

* **WebSocket connection management** — connect, pause, resume, and auto-reconnect
* **Channel subscriptions** — default, targeted, group, secure (encrypted), and CRDT channels
* **Push messages** — send structured payloads with optional per-user targeting
* **Event listening** — receive messages via `emitter.on()`
* **Presence tracking** — observe users online in real time
* **End-to-end encryption** — automatic encryption on secure channels
* **Interceptors** — intercept and modify messages
* **Shared objects (CRDT)** — real-time collaborative state


## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/aiotrixdev/art-swift-adk.git", from: "1.0.0")
]
```

Or in Xcode:

**File → Add Packages → Paste repository URL**


## Configuration

### 1. Create credentials

Store your ART credentials securely:

```swift
let creds = CredentialStore(
    environment:  "YOUR_ENV",
    projectKey:   "YOUR_PROJECT_KEY",
    orgTitle:     "YOUR_ORG",
    clientID:     "CLIENT_ID",
    clientSecret: "CLIENT_SECRET"
)
```


### 2. Get a user passcode

ART uses a short-lived passcode for authentication:

```swift
func fetchPasscode(creds: CredentialStore) async throws -> String {
    let url = URL(string: "https://dev.arealtimetech.com/ws/v1/connect/passcode")!
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    request.addValue(creds.clientID, forHTTPHeaderField: "Client-Id")
    request.addValue(creds.clientSecret, forHTTPHeaderField: "Client-Secret")
    request.addValue(creds.orgTitle, forHTTPHeaderField: "X-Org")
    request.addValue(creds.environment, forHTTPHeaderField: "Environment")
    request.addValue(creds.projectKey, forHTTPHeaderField: "ProjectKey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body: [String: Any] = [
        "username": "john_doe",
        "first_name": "John",
        "last_name": "Doe"
    ]
    
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    
    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let dataObj = json?["data"] as? [String: Any]
    
    return dataObj?["passcode"] as? String ?? ""
}
```

## Quick Start

```swift
import ARTSdk

let passcode = try await fetchPasscode(creds: creds)

let adk = Adk(config: AdkConfig(
    uri: "ws.arealtimetech.com",
    authToken: passcode,
    getCredentials: { creds }
))

adk.on("connection") { data in
    if let conn = data as? ConnectionDetail {
        print("Connected → \(conn.connectionId)")
    }
}

adk.on("close") { reason in
    print("Closed:", reason)
}

try await adk.connect()

let sub = try await adk.subscribe(channel: "room-42")

sub.emitter.on("message") { data in
    print("Received:", data)
}

try await sub.push(
    event: "message",
    data: ["text": "Hello ART!"]
)
```

## Connecting

```swift
try await adk.connect()
```

Safe usage:

```swift
do {
    try await adk.connect()
} finally {
    await adk.disconnect()
}
```

Check state:

```swift
adk.getState() // connected | retrying | paused | stopped
```

## Subscribing to a Channel

```swift
let sub = try await adk.subscribe(channel: "room-42")

if let live = sub as? LiveObjSubscription {
    // CRDT channel
}
```

Unsubscribe:

```swift
await sub.unsubscribe()
```


## Pushing Messages

```swift
try await sub.push(
    event: "message",
    data: ["text": "Hello"]
)
```

Targeted messaging:

```swift
try await sub.push(
    event: "message",
    data: ["text": "Hi Bob"],
    options: PushConfig(to: ["bob"])
)
```

## Receiving Messages

```swift
sub.emitter.on("message") { data in
    print("Got:", data)
}
```

## Presence

```swift
let cancel = try await sub.fetchPresence { users in
    print("Online:", users)
}

// later
await cancel()
```

## Encrypted Channels

```swift
try await adk.generateKeyPair()

let secure = try await adk.subscribe(channel: "SECURE_CHANNEL")

try await secure.push(
    event: "message",
    data: ["text": "Private"],
    options: PushConfig(to: ["bob"])
)

secure.emitter.on("message") { data in
    print("Decrypted:", data)
}
```

## Shared Object Channels (CRDT)

```swift
let sub = try await adk.subscribe(channel: "CRDT_CHANNEL")

if let live = sub as? LiveObjSubscription {
    
    // Write
    live.state()["document"]["title"].set("My Doc")
    await live.flush()
    
    // Read
    let snapshot = await live.query(path: "document").execute()
    print(snapshot)
    
    // Listen
    let dispose = await live.query(path: "document").listen { data in
        print("Updated:", data)
    }
    
    dispose()
}
```

### Array Operations

```swift
let items = live.state()["items"]

items.push("alpha")
items.unshift("zero")
items.pop()
items.removeAt(2)
items.splice(start: 1, deleteCount: 1, insert: ["x"])

await live.flush()
```

## Interceptors

```swift
try await adk.intercept(interceptor: "filter") { payload, resolve, reject in
    
    if let text = payload["text"] as? String,
       text.contains("anyword") {
        reject("Blocked")
        return
    }
    
    resolve(payload)
}
```


## Connection Lifecycle

```swift
adk.on("connection") { data in
    print("Connected")
}

adk.on("close") { _ in
    print("Closed")
}

adk.pause()
await adk.resume()
await adk.disconnect()
```

## Documentation

Full documentation is available at **[docs.arealtimetech.com/docs/adk](https://docs.arealtimetech.com/docs/adk/)**.

| Topic | Link |
|---|---|
| Overview | [ADK Overview](https://docs.arealtimetech.com/docs/adk/) |
| Installation | [Swift Installation](https://docs.arealtimetech.com/docs/adk/swift/installation) |
| Publish & Subscribe | [Pub/Sub Docs](https://docs.arealtimetech.com/docs/adk/swift/pub-sub) |
| Connection Management | [Connection Docs](https://docs.arealtimetech.com/docs/adk/swift/connection-management) |
| User Presence | [Presence Docs](https://docs.arealtimetech.com/docs/adk/swift/user-presence) |
| Encrypted Channels | [Encryption Docs](https://docs.arealtimetech.com/docs/adk/swift/encrypted-channel) |
| Shared Object Channels | [Shared Object Docs](https://docs.arealtimetech.com/docs/adk/swift/shared-object-channel) |
| Interceptors | [Interceptor Docs](https://docs.arealtimetech.com/docs/adk/swift/intercept-channel) |


## License

Released under the [MIT License](LICENSE).

