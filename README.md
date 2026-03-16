# ARTSdk – Swift

A complete Swift port of the ART ADK TypeScript SDK.  
Targets **iOS 16+ / macOS 13+**.  
Uses [TweetNaclSwift](https://github.com/bitmark-inc/tweetnacl-swiftwrap) for NaCl box encryption.

---

## Installation (Swift Package Manager)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<your-org>/ADK.git", from: "1.0.0"),
]
```

Or add via Xcode → File → Add Packages.

---

## Quick Start

```swift
import ARTSdk

// 1. Create Adk instance
let adk = Adk(config: AdkConfig(uri: "your-server.com"))

// 2. Listen for connection
adk.on("connection") { data in
    if let conn = data as? ConnectionDetail {
        print("Connected: \(conn.connectionId)")
    }
}

// 3. Connect
await adk.connect()

// 4. Subscribe to a channel
let sub = try await adk.subscribe(channel: "my-channel")
if let subscription = sub as? Subscription {
    subscription.bind(event: "my-event") { data in
        print("Received: \(data)")
    }
}
```

---

## Auth – credentials

```swift
// Static credentials
let config = AdkConfig(
    uri: "your-server.com",
    getCredentials: {
        CredentialStore(
            environment:  "production",
            projectKey:   "my-project",
            orgTitle:     "my-org",
            clientID:     "abc",
            clientSecret: "secret"
        )
    }
)
```

---

## LiveObject (CRDT) Channel

```swift
let sub = try await adk.subscribe(channel: "shared-data-channel")
guard let liveObj = sub as? LiveObjSubscription else { return }

// Read via @dynamicMemberLookup proxy
let state = liveObj.state()
let name = state.user.name.value as? String

// Write
state.user.name.set("Alice")
state.scores.push(42)

// Query with listener
let handle = liveObj.query(path: "user.name")
_ = await handle.listen { newValue in
    print("Name changed: \(newValue)")
}
```

---

## Presence

```swift
let unsubscribe = try await subscription.fetchPresence(callback: { users in
    print("Online users: \(users)")
}, options: .init(unique: true))

// Later:
await unsubscribe()
```

---

## Secure Channel (E2E Encryption)

```swift
// Generate and register a key pair once
let keyPair = try adk.generateKeyPair()
try await adk.setKeyPair(keyPair)

// Then subscribe/push to a channel of type "secure" – encryption/decryption is automatic
```

---

## Interceptors

```swift
let interception = try await adk.intercept(interceptor: "my-interceptor") { payload, resolve, reject in
    // Inspect / modify / allow or block the message
    var modified = payload
    modified["processed"] = true
    resolve(modified)
}
```

---

## REST API helper

```swift
let result: [String: Any] = try await adk.call(
    endpoint: "/v1/some-endpoint",
    options: CallApiProps(method: "POST", payload: ["key": "value"])
)
```

---

## Connection lifecycle

```swift
adk.pause()              // suspend, stops reconnection
await adk.resume()       // resume
await adk.disconnect()   // full teardown
print(adk.getState())    // "connected" | "paused" | "retrying" | "stopped"
```

---

## File structure

```
Sources/ARTSdk/
├── Config/
│   └── Constant.swift          // URL configuration
├── Types/
│   ├── AuthTypes.swift          // AdkConfig, CredentialStore, AuthData …
│   ├── ChannelTypes.swift       // ChannelConfig
│   ├── SocketTypes.swift        // ConnectionDetail, PushConfig, IWebsocketHandler …
│   └── CryptoTypes.swift        // KeyPairType
├── Auth/
│   └── Auth.swift               // Singleton auth, JWT decode, token refresh
├── Crypto/
│   └── CryptoBox.swift          // NaCl box encrypt/decrypt via TweetNacl
├── CRDT/
│   ├── CRDTTypes.swift          // LDValue, LDEntry, LDMap, LDArray, CRDTOperation
│   ├── CRDTUtils.swift          // generateId, toLDValue, linearizeRGA, ARTError
│   └── CRDT.swift               // CRDT engine + @dynamicMemberLookup CRDTProxy
└── WebSocket/
    ├── EventEmitter.swift        // Lightweight EventEmitter
    ├── HelperFunctions.swift     // subscribe_to_channel, unsubscribe, get_interceptor_config
    ├── LongPollClient.swift      // HTTP long-poll fallback
    ├── BaseSubscription.swift    // Base class (ack, presence, push, buffer)
    ├── Subscription.swift        // Standard pub/sub channel
    ├── LiveObjSubscription.swift // CRDT shared-object channel
    ├── Interception.swift        // Interceptor handler
    ├── Socket.swift              // Core socket (WS → SSE → LongPoll, heartbeat)
    └── Adk.swift                 // Public entry point (mirrors adk.ts exactly)
```
