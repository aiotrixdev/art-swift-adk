# Changelog

All notable changes to this project will be documented in this file.

## [1.0.1]
### Added
- AI Agent support
  - Agent API
  - AgentThread
  - Run lifecycle
  - Typed agent events
  - Human-in-the-Loop (HITL) support
  - Agent trace listeners

- AI Orchestrator support
  - Orchestrator API
  - OrchestratorThread
  - Thread-scoped workflow communication
  - Human-in-the-Loop (HITL) reply support
  - Workflow trace listeners

### Improved
- Added comprehensive Agent documentation.
- Added comprehensive Orchestrator documentation.
- Updated README with AI workflow examples.
- Updated SwiftUI example application with Agent Tester.
- Improved package documentation for Swift Package Index.

## [1.0.0]

### Initial Version
- Initial release of ART ADK
- WebSocket connection management
- Channel subscription (broadcast, targeted, group, encrypted, shared)
- Message push functionality
- Event listening
- User presence tracking
- Encrypted channel support
- Interceptors for message processing
- CRDT-based shared object channels

[1.0.3]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.1
[1.0.0]: https://github.com/aiotrixdev/art-swift-adk/releases/tag/1.0.0
