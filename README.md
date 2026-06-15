# circle

circle is a macOS-only starter implementation of the provided Surge-like proxy roadmap.

The current build includes:

- A native SwiftUI dashboard shell.
- `CoreProxy` models for profiles, proxies, policy groups, DNS, MITM, scripts, and traffic logs.
- A Surge-like `.conf` parser and serializer.
- A basic rule engine with policy routing (`DIRECT`, `REJECT`, named proxies, policy groups).
- A SwiftNIO HTTP/1.1 proxy on `127.0.0.1:8888` with `CONNECT` tunneling and plain HTTP forwarding.
- HTTPS MITM decryption with a local CA, per-host leaf certificates (LRU cache), and TLS termination via NIOSSL.
- WebSocket dashboard API on `127.0.0.1:8234` for live traffic streaming and remote clients.
- Real-time dashboard with request table, policy/status filters, request inspector (headers, bodies, timing), and bandwidth graph.
- Menu bar status item with quick proxy toggle.
- macOS system proxy enable/disable via `networksetup`.
- MITM settings UI: generate CA, install in Keychain, export `.pem`, view fingerprint and expiry.
- Unit tests for parser, rule evaluation, policy routing, certificate management, and dashboard messages.

Next milestones from `PLAN.md`: SQLite request log, DNS engine, and additional proxy protocols.

## Build

```sh
swift build
```

## Test

```sh
swift test
```

## Run

```sh
swift run circle
```

The dashboard WebSocket API listens on `ws://127.0.0.1:8234` while the proxy is running. Connect and receive JSON messages (`snapshot`, `request`, `state`, `bandwidth`, `cleared`). Send `{"type":"clear"}` to clear the log remotely.
# circle
