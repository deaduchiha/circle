# circle

circle is a macOS-only starter implementation of the provided Surge-like proxy roadmap.

The current build includes:

- A native SwiftUI dashboard shell.
- `CoreProxy` models for profiles, proxies, policy groups, DNS, MITM, scripts, and traffic logs.
- A Surge-like `.conf` parser and serializer.
- A basic rule engine with policy routing (`DIRECT`, `REJECT`, named proxies, policy groups).
- Policy groups: `select`, `url-test` (latency-based auto-switch), `fallback`, and `load-balance`.
- A SwiftNIO HTTP/1.1 proxy on `127.0.0.1:8888` with `CONNECT` tunneling and plain HTTP forwarding.
- HTTPS MITM decryption with a local CA, per-host leaf certificates (LRU cache), and TLS termination via NIOSSL.
- WebSocket dashboard API on `127.0.0.1:8234` for live traffic streaming and remote clients.
- Real-time dashboard with request table, policy/status filters, request inspector (headers, bodies, timing), and bandwidth graph.
- Menu bar status item with quick proxy toggle.
- macOS system proxy enable/disable via `networksetup`.
- MITM settings UI: generate CA, install in Keychain, export `.pem`, view fingerprint and expiry.
- Unit tests for parser, rule evaluation, policy routing, certificate management, dashboard messages, and GeoIP.

GeoIP rules use MaxMind GeoLite2-Country. Download the database with `./Scripts/download-geolite2.sh` or configure a license key in Settings for automatic updates.

Profile management supports multiple stored profiles, `#!include`, per-profile module toggles, a syntax-highlighted editor, and optional iCloud sync (Settings → Profiles).

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

**Recommended** — launches as a proper macOS app with a visible window:

```sh
./Scripts/run-app.sh
```

This builds the project, wraps the binary in `.build/Circle.app`, and opens it with macOS `open`.

You can also run the raw binary from Terminal (logs stay in the terminal, window may open behind other apps):

```sh
swift run circle
```

If the window does not appear after `swift run circle`, click the **circle** icon in the Dock or use **Cmd+Tab** to switch to it. The menu bar network icon also provides **Open Dashboard**.

The dashboard WebSocket API listens on `ws://127.0.0.1:8234` while the proxy is running. Connect and receive JSON messages (`snapshot`, `request`, `state`, `bandwidth`, `cleared`). Send `{"type":"clear"}` to clear the log remotely.
