# PLAN.md — Building a Surge-like Network Proxy Tool

> A complete engineering roadmap for building a macOS + iOS network debugging proxy,
> rule-based router, and traffic analysis tool comparable to [Surge](https://nssurge.com/).

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Feature Requirements](#2-feature-requirements)
3. [Architecture Overview](#3-architecture-overview)
4. [Tech Stack](#4-tech-stack)
5. [Repository Structure](#5-repository-structure)
6. [Phase 0 — Foundation](#phase-0--foundation-weeks-14)
7. [Phase 1 — HTTP/HTTPS Proxy + Dashboard](#phase-1--httphttps-proxy--dashboard-weeks-512)
8. [Phase 2 — Rule Engine + Profile System](#phase-2--rule-engine--profile-system-weeks-1318)
9. [Phase 3 — DNS Engine](#phase-3--dns-engine-weeks-1924)
10. [Phase 4 — Proxy Protocols](#phase-4--proxy-protocols-weeks-2534)
11. [Phase 5 — macOS System-Level Traffic](#phase-5--macos-system-level-traffic-weeks-3544)
12. [Phase 6 — iOS Port](#phase-6--ios-port-weeks-4556)
13. [Phase 7 — Scripting Engine](#phase-7--scripting-engine-weeks-5764)
14. [Phase 8 — Polish & Advanced Features](#phase-8--polish--advanced-features-weeks-6580)
15. [Data Models](#15-data-models)
16. [Config File Format](#16-config-file-format)
17. [Testing Strategy](#17-testing-strategy)
18. [Open Source References](#18-open-source-references)
19. [Apple Entitlements & App Store](#19-apple-entitlements--app-store)
20. [Timeline Summary](#20-timeline-summary)

---

## 1. Project Overview

This document is the complete engineering plan for building a Surge-equivalent network toolbox for macOS and iOS. The app intercepts all device network traffic, routes requests using a flexible rule system, forwards traffic through proxy servers, decrypts HTTPS for debugging, and exposes a scripting API.

### Goals

- Intercept and log all HTTP, HTTPS, TCP, and UDP traffic on a device
- Route requests through flexible domain/IP/GeoIP/process-based rules
- Forward traffic through multiple upstream proxy protocols (WireGuard, VMess, Shadowsocks, SOCKS5, etc.)
- Decrypt HTTPS traffic using MITM with a user-trusted local CA
- Provide a real-time dashboard for traffic analysis
- Support JavaScript scripting to modify requests/responses
- Ship on macOS (primary) and iOS (secondary)

### Non-Goals (v1)

- Windows or Linux support
- Browser extension
- Cloud sync of profiles (v2)
- Paid proxy server hosting (not a VPN service)

---

## 2. Feature Requirements

### 2.1 Traffic Interception

| Feature | macOS | iOS |
|---|---|---|
| HTTP/HTTPS system proxy | ✅ | ✅ |
| Enhanced mode (TUN/VIF) — all apps regardless of proxy support | ✅ | ✅ |
| Gateway mode (handle traffic from other LAN devices) | ✅ | ❌ |
| Capture traffic from apps ignoring system proxy | ✅ | ✅ |
| Capture cellular network traffic | N/A | ✅ |

### 2.2 Proxy Protocol Support

- HTTP / HTTPS
- SOCKS5 / SOCKS5-TLS
- Shadowsocks
- VMess
- Trojan
- TUIC
- Hysteria 2
- WireGuard
- SSH tunnel
- AnyTLS

### 2.3 Rule System

- `DOMAIN` — exact domain match
- `DOMAIN-SUFFIX` — domain suffix match (e.g. `.google.com`)
- `DOMAIN-KEYWORD` — keyword in domain
- `DOMAIN-SET` — bulk domain list from file
- `IP-CIDR` — IPv4 CIDR range
- `IP-CIDR6` — IPv6 CIDR range
- `GEOIP` — GeoIP country code (MaxMind GeoLite2)
- `PROCESS-NAME` — macOS process name
- `URL-REGEX` — regex match on full URL
- `AND` / `OR` / `NOT` — logical combinators
- `RULE-SET` — external rule list file
- `FINAL` — catch-all fallback rule

### 2.4 Policy Types

- `DIRECT` — connect without proxy
- `REJECT` — drop the connection
- `REJECT-TINYGIF` — return 1×1 GIF (ad blocking)
- Named proxy — specific upstream server
- `select` group — manual selection
- `url-test` group — auto-select fastest
- `fallback` group — failover
- `load-balance` group — round-robin

### 2.5 DNS

- Custom upstream DNS servers per domain
- DNS-over-HTTPS (DoH)
- DNS-over-TLS (DoT)
- Local DNS mapping (wildcard, alias, custom server)
- Fake-IP mode (virtual IPs from `198.18.0.0/16`)
- Simultaneous multi-server query (use fastest)
- DNS cache with TTL

### 2.6 HTTP Processing

- MITM HTTPS decryption with per-host cert generation
- URL rewrite (redirect or modify request URL)
- Header rewrite (add/remove/modify request and response headers)
- Body rewrite (regex replace in response body)
- Mock responses (return local file or static body)
- Request blocking

### 2.7 Scripting

- JavaScript API via JavaScriptCore
- Hook points: request, response, DNS, rule evaluation, cron, network-changed event
- `$request` / `$response` — read/write headers and body
- `$httpClient` — make outbound HTTP calls
- `$done()` — resolve request with modified content
- `$notification.post()` — push notifications
- `$prefs` — persistent key-value store
- `$utils` — utilities (encoding, hashing, etc.)

### 2.8 Dashboard

- Real-time request log (domain, method, status, size, timing)
- Filter by policy, status code, process name, keyword
- Request/response inspector (headers, body, decoded HTTPS)
- Active connection count, bandwidth graph
- Policy switching UI
- DNS lookup tool
- Connectivity test
- Remote Dashboard (connect iOS device from Mac over Wi-Fi or USB)

---

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    UI Layer                              │
│   Dashboard (SwiftUI)  │  Config Editor  │  Script UI   │
└───────────────────────────┬─────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────┐
│                  Core Engine (Swift)                     │
│  Rule Engine  │  MITM Engine  │  DNS Resolver  │  JS VM  │
└───────────────────────────┬─────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────┐
│             Traffic Interception Layer                   │
│   macOS: utun TUN/VIF + lwIP    │   iOS: NEPacketTunnel  │
└───────────────────────────┬─────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────┐
│              Proxy Protocol Layer (Swift + C)            │
│  SOCKS5 │ Shadowsocks │ VMess │ WireGuard │ Trojan │ … │
└─────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Shared Core Package** — all business logic lives in a Swift Package (`CoreProxy`) imported by both macOS and iOS targets. Platform-specific code (TUN setup, NetworkExtension) is isolated behind protocol abstractions.
- **SwiftNIO for all async I/O** — connection handling, proxy protocol implementations, and the HTTP proxy server all use SwiftNIO event loops.
- **BoringSSL for TLS** — used for MITM cert generation and TLS termination. Vendored as a Swift package.
- **lwIP for userspace TCP/IP** — handles raw IP packets from the TUN interface on macOS and the `NEPacketTunnelProvider` on iOS.
- **JavaScriptCore** — Apple's built-in JS engine. No external JS runtime needed.
- **WebSocket-based Dashboard API** — the core engine exposes a local WebSocket server; the SwiftUI dashboard connects to it. This also powers remote iOS dashboard access.

---

## 4. Tech Stack

| Layer | Technology | Notes |
|---|---|---|
| Language | Swift 5.10+ | Primary language |
| Low-level networking | C / C++ | lwIP, BoringSSL, protocol libs |
| Swift/C bridge | Swift Package Manager + modulemaps | Bridge C libraries |
| Async I/O | SwiftNIO | All connection handling |
| TLS (MITM) | BoringSSL | Per-host cert generation |
| TLS (system) | Apple Security.framework | Certificate installation |
| Userspace TCP/IP | lwIP | Packet processing from TUN |
| Scripting | JavaScriptCore | Built into macOS/iOS |
| GeoIP | MaxMind GeoLite2 | Country-code matching |
| WireGuard | wireguard-go (via CGo bridge) | Official WireGuard impl |
| macOS UI | SwiftUI | macOS 13+ minimum |
| iOS UI | SwiftUI | iOS 16+ minimum |
| iOS interception | NetworkExtension framework | Apple entitlement required |
| Dashboard API | WebSocket (SwiftNIO) | Local + remote dashboard |
| Config format | Custom INI-like `.conf` | Surge-compatible |
| Database | SQLite (GRDB.swift) | Request log storage |
| Testing | XCTest + Swift Testing | Unit + integration tests |

---

## 5. Repository Structure

```
surge-clone/
├── App/
│   ├── macOS/                        # macOS app target
│   │   ├── AppDelegate.swift
│   │   ├── StatusBarController.swift
│   │   ├── Dashboard/
│   │   │   ├── DashboardView.swift
│   │   │   ├── RequestListView.swift
│   │   │   ├── RequestDetailView.swift
│   │   │   └── BandwidthGraphView.swift
│   │   ├── Config/
│   │   │   ├── ProfileEditorView.swift
│   │   │   └── RuleEditorView.swift
│   │   ├── Scripts/
│   │   │   └── ScriptManagerView.swift
│   │   └── TUN/
│   │       ├── TUNInterface.swift    # utun setup
│   │       └── SystemProxyManager.swift
│   └── iOS/                          # iOS app target
│       ├── AppDelegate.swift
│       ├── Dashboard/
│       └── PacketTunnel/             # App Extension
│           ├── PacketTunnelProvider.swift
│           └── Info.plist
├── CoreProxy/                        # Shared Swift Package
│   ├── Package.swift
│   ├── Sources/
│   │   ├── CoreProxy/
│   │   │   ├── Models/
│   │   │   │   ├── Profile.swift
│   │   │   │   ├── Rule.swift
│   │   │   │   ├── Policy.swift
│   │   │   │   ├── ProxyConfig.swift
│   │   │   │   └── Request.swift
│   │   │   ├── Config/
│   │   │   │   └── ProfileParser.swift
│   │   │   ├── RuleEngine/
│   │   │   │   ├── RuleEngine.swift
│   │   │   │   ├── RuleMatcher.swift
│   │   │   │   └── GeoIPResolver.swift
│   │   │   ├── Proxy/
│   │   │   │   ├── ProxyServer.swift       # SwiftNIO HTTP proxy
│   │   │   │   ├── MITMEngine.swift
│   │   │   │   ├── CertificateManager.swift
│   │   │   │   └── ConnectionManager.swift
│   │   │   ├── DNS/
│   │   │   │   ├── DNSResolver.swift
│   │   │   │   ├── FakeIPPool.swift
│   │   │   │   └── DNSCache.swift
│   │   │   ├── Protocols/
│   │   │   │   ├── SOCKS5Handler.swift
│   │   │   │   ├── ShadowsocksHandler.swift
│   │   │   │   ├── VMessHandler.swift
│   │   │   │   ├── TrojanHandler.swift
│   │   │   │   ├── WireGuardHandler.swift
│   │   │   │   ├── TUICHandler.swift
│   │   │   │   └── Hysteria2Handler.swift
│   │   │   ├── Scripting/
│   │   │   │   ├── ScriptEngine.swift
│   │   │   │   ├── JSContext+ProxyAPI.swift
│   │   │   │   └── ScriptScheduler.swift
│   │   │   ├── Dashboard/
│   │   │   │   ├── DashboardServer.swift   # WebSocket server
│   │   │   │   └── RequestLogger.swift
│   │   │   └── PacketProcessor/
│   │   │       ├── PacketProcessor.swift   # lwIP bridge
│   │   │       ├── TCPStack.swift
│   │   │       └── UDPStack.swift
│   │   └── CLwIP/                    # lwIP C library bridge
│   │       ├── include/
│   │       └── module.modulemap
│   └── Tests/
│       ├── RuleEngineTests/
│       ├── DNSTests/
│       ├── MITMTests/
│       └── ProtocolTests/
├── Vendors/
│   ├── lwip/                         # lwIP source
│   ├── boringssl/                    # BoringSSL source
│   └── wireguard-go/                 # WireGuard Go source
├── Scripts/                          # Build scripts
│   ├── build-wireguard.sh
│   └── generate-certs.sh
├── Resources/
│   ├── GeoLite2-Country.mmdb         # MaxMind GeoIP DB
│   └── DefaultProfile.conf
├── Tests/
│   └── IntegrationTests/
├── .github/
│   └── workflows/
│       └── ci.yml
├── PLAN.md                           # This file
└── README.md
```

---

## Phase 0 — Foundation (weeks 1–4)

### Goals

Set up the project skeleton, tooling, and core data models before writing any networking code.

### Implementation status (`circle`)

Partial — macOS SwiftPM app only (no Xcode multi-target / iOS yet). See checked items below.

### Tasks

#### 0.1 Project setup

- [ ] Create Xcode project with three targets:
  - `SurgeClone` (macOS app)
  - `SurgeCloneiOS` (iOS app)
  - `PacketTunnel` (iOS Network Extension)
- [x] Create `CoreProxy` Swift Package, add as local dependency to all targets — *SwiftPM `circle` executable + `CoreProxy` library*
- [ ] Configure code signing and provisioning profiles
- [x] Set minimum deployments: macOS 13.0, iOS 16.0 — *macOS 13 only for now*
- [ ] Set up GitHub repo, branch protection, PR templates

#### 0.2 CI pipeline

- [x] GitHub Actions workflow: build + test on every PR
- [ ] SwiftLint integration
- [ ] Code coverage reporting
- [ ] Notarization script for macOS builds

#### 0.3 Core data models

```swift
// Profile.swift
struct Profile: Codable {
    var general: GeneralConfig
    var proxies: [ProxyConfig]
    var proxyGroups: [PolicyGroup]
    var rules: [Rule]
    var hosts: [String: String]
    var dnsConfig: DNSConfig
    var mitm: MITMConfig
    var scripts: [ScriptConfig]
}

// Rule.swift
enum RuleType: String, Codable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case domainSet = "DOMAIN-SET"
    case ipCIDR = "IP-CIDR"
    case ipCIDR6 = "IP-CIDR6"
    case geoIP = "GEOIP"
    case processName = "PROCESS-NAME"
    case urlRegex = "URL-REGEX"
    case ruleSet = "RULE-SET"
    case final = "FINAL"
}

struct Rule: Codable {
    var type: RuleType
    var value: String
    var policy: String
    var options: [String: String]
}

// ProxyConfig.swift
struct ProxyConfig: Codable {
    var name: String
    var type: ProxyType      // http, https, socks5, ss, vmess, trojan, wireguard...
    var host: String
    var port: Int
    var parameters: [String: String]
}
```

- [x] Core data models implemented (`Sources/CoreProxy/Models.swift`)

#### 0.4 Config file parser

- [x] Implement INI-like `.conf` parser for Surge-compatible profiles
- [x] Support sections: `[General]`, `[Proxy]`, `[Proxy Group]`, `[Rule]`, `[Host]`, `[DNS]`, `[MITM]`, `[Script]`
- [ ] Support `#!include` for external files
- [x] Round-trip: parse → modify → serialize back to `.conf`
- [x] Unit tests for all rule types and edge cases — *parser + rule engine tests; not exhaustive per rule type*

#### 0.5 Logging infrastructure

- [x] Structured logging with `swift-log`
- [x] SQLite request log via GRDB.swift
- [x] Log rotation (keep last 10,000 requests in DB)

---

## Phase 1 — HTTP/HTTPS Proxy + Dashboard (weeks 5–12)

### Goals

Build a working HTTP/HTTPS debugging proxy that users can point their browser at. Ship the first real feature.

### Implementation status (`circle`)

| Section | Status | Notes |
|---|---|---|
| 1.1 HTTP proxy | **Done** | SwiftNIO server, system proxy, upstream HTTP proxy forwarding |
| 1.2 MITM engine | **Done** | EC P-256 CA, Keychain storage, NIOSSL (BoringSSL) TLS termination |
| 1.3 Certificate UI | **Done** | Settings → MITM tab |
| 1.4 Dashboard | **Mostly done** | WebSocket API, inspector, filters, bandwidth graph, menu bar; DNS timing deferred to Phase 3 |
| 1.5 Rule engine | **Done** | Exceeds stub scope (see below) |

### Tasks

#### 1.1 HTTP proxy server (SwiftNIO)

- [x] Local HTTP/1.1 proxy on `127.0.0.1:8888`
- [x] Handle `CONNECT` method for HTTPS tunneling (pass-through, no decryption yet)
- [x] Handle plain HTTP requests (forward to upstream)
- [x] Set as macOS system proxy via `networksetup -setwebproxy` and `-setsecurewebproxy`
- [x] Configurable listen port in `[General]` section

```swift
// ProxyServer.swift — skeleton
import NIO
import NIOHTTP1

final class ProxyServer {
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    func start(host: String, port: Int) async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(HTTPRequestDecoder()),
                    HTTPResponseEncoder(),
                    ProxyHandler()
                ])
            }
        channel = try await bootstrap.bind(host: host, port: port).get()
    }
}
```

#### 1.2 MITM engine

- [x] Generate a local CA certificate and private key (RSA 2048 or EC P-256) — *implemented with EC P-256*
- [x] Store CA cert + key securely in Keychain
- [x] Export CA cert as `.pem` / `.crt` for user installation
- [x] Per-request: generate leaf certificate signed by local CA matching the target hostname
- [x] Cache generated leaf certs (in-memory LRU, keyed by hostname)
- [x] TLS termination using BoringSSL: intercept the CONNECT tunnel, establish two TLS connections (client↔proxy and proxy↔server) — *via NIOSSL*
- [x] Forward decrypted traffic through the rule engine

```swift
// CertificateManager.swift — interface
protocol CertificateManager {
    func generateCA() throws -> (certificate: Certificate, key: PrivateKey)
    func leafCertificate(for hostname: String) throws -> (certificate: Certificate, key: PrivateKey)
    func installCAInKeychain(_ cert: Certificate) throws
}
```

#### 1.3 Certificate generator UI

- [x] "Generate CA Certificate" button in Preferences → MITM tab
- [x] One-click installation into macOS System Keychain with trust for SSL
- [x] Show certificate fingerprint and expiry date
- [x] Export button for manual installation on other devices

#### 1.4 Real-time Dashboard (SwiftUI)

- [x] WebSocket server on `127.0.0.1:8234` (internal API)
- [x] `RequestListView` — scrollable table: timestamp, method, host, path, status, size, policy, latency
- [x] `RequestDetailView` — selected request inspector:
  - [x] Request headers + body
  - [x] Response headers + body
  - [x] Timing breakdown (TCP connect, TLS, TTFB, total)
  - [ ] Timing breakdown (DNS) — *deferred to Phase 3 DNS engine*
  - [x] Which rule matched
- [x] Filter bar: keyword search, policy filter, status filter
- [x] Clear log button
- [x] Bandwidth graph (live bytes/sec in/out using Charts framework)
- [x] Status bar item with quick toggle (enable/disable proxy)

#### 1.5 Basic rule engine (stub)

- [x] Support `DOMAIN`, `DOMAIN-SUFFIX`, `FINAL` rules only — *also implements `DOMAIN-KEYWORD`, `URL-REGEX`, `IP-CIDR`, `PROCESS-NAME` stubs; `GEOIP` / `DOMAIN-SET` / `RULE-SET` deferred to Phase 2*
- [x] Policies: `DIRECT`, `REJECT`, named proxy — *also `REJECT-TINYGIF` and policy group resolution*
- [x] Apply rules to each intercepted request

---

## Phase 2 — Rule Engine + Profile System (weeks 13–18)

### Goals

Complete the rule matching system and make profiles fully editable in-app.

### Tasks

#### 2.1 Full rule engine

- [ ] Implement all rule types from section 2.3
- [ ] Trie-based domain matching for O(n) lookups on large domain lists
- [ ] CIDR range matching (IPv4 and IPv6) using bitmasking
- [ ] Regex compilation cache for `URL-REGEX` rules
- [ ] `PROCESS-NAME` matching using `proc_pidinfo` (macOS) / `NEFilterDataProvider` (iOS)
- [ ] `AND` / `OR` / `NOT` logical combinators
- [ ] `RULE-SET` — download and cache external rule files
- [ ] `DOMAIN-SET` — bulk load from newline-separated file
- [ ] Rule test caching (cache match results per hostname, flush on network change)
- [ ] Rule ordering: first match wins

#### 2.2 GeoIP integration

- [ ] Bundle MaxMind GeoLite2-Country.mmdb in app resources
- [ ] Swift wrapper around mmdb-swift or custom reader
- [ ] `GEOIP,CN,DIRECT` type rules
- [ ] Auto-update DB (download newer mmdb on launch if >30 days old)

#### 2.3 Policy groups

```swift
enum PolicyGroupType: String, Codable {
    case select        // manual selection via UI
    case urlTest       // auto-select by latency test
    case fallback      // use first available
    case loadBalance   // round-robin
}

struct PolicyGroup: Codable {
    var name: String
    var type: PolicyGroupType
    var policies: [String]
    var testURL: String?          // for url-test group
    var testInterval: Int?        // seconds
    var tolerance: Int?           // ms — only switch if delta > tolerance
}
```

- [ ] `url-test`: ping `testURL` through each proxy, rank by latency, auto-switch
- [ ] `fallback`: try proxies in order, skip unavailable ones
- [ ] `load-balance`: distribute connections round-robin across group members
- [ ] Policy group UI: show latency badge per member, allow manual override
- [ ] Background latency testing every `testInterval` seconds

#### 2.4 Profile management

- [ ] Profile list: create, duplicate, rename, delete
- [ ] Import profile from URL (download `.conf` from remote)
- [ ] Export profile to file
- [ ] `#!include` support — merge external files into profile
- [ ] Module system: enable/disable individual modules per profile
- [ ] Profile editor: raw text editor with syntax highlighting (highlight rule types, comments)
- [ ] iCloud sync of profiles (optional, behind feature flag)

---

## Phase 3 — DNS Engine (weeks 19–24)

### Goals

Replace the system DNS resolver with a fully custom implementation that supports encryption, Fake-IP, and per-domain server assignment.

### Tasks

#### 3.1 Custom DNS resolver

```swift
// DNSResolver.swift
protocol DNSResolver {
    func resolve(hostname: String, type: DNSRecordType) async throws -> [DNSRecord]
}

struct DNSConfig: Codable {
    var servers: [String]              // upstream servers
    var defaultDomain: [String]        // search domains
    var hijackDNS: Bool                // intercept all DNS queries
    var fakeIPEnabled: Bool
    var fakeIPFilter: [String]         // domains excluded from fake-IP
    var localMapping: [String: String] // [Host] section
    var dohServers: [String]           // DNS-over-HTTPS URLs
    var dotServers: [String]           // DNS-over-TLS host:port
}
```

- [ ] UDP DNS client (standard port 53)
- [ ] DNS-over-HTTPS client (JSON and wire format)
- [ ] DNS-over-TLS client (TLS wrapped UDP/TCP)
- [ ] Query all configured servers simultaneously, use first response
- [ ] DNS cache with TTL, max 10,000 entries, LRU eviction
- [ ] Intercept DNS queries from TUN interface (Phase 5 prerequisite)

#### 3.2 Local DNS mapping

- [ ] Exact hostname → IP mapping
- [ ] Wildcard hostname → IP mapping (`*.example.com`)
- [ ] Hostname → custom DNS server (`example.com → 8.8.8.8`)
- [ ] Alias: hostname → another hostname (CNAME-like)
- [ ] Reload `[Host]` section on profile change

#### 3.3 Fake-IP mode

- [ ] Maintain a pool of virtual IPs in `198.18.0.0/15` range (131,072 addresses)
- [ ] On DNS query: assign a virtual IP to the hostname, cache the mapping
- [ ] When a TCP connection arrives at a fake IP: look up the real hostname, resolve via DNS, connect to real server
- [ ] Excluded domains (`fakeip-filter`) resolve normally
- [ ] Persist fake-IP mappings across sessions

#### 3.4 DNS UI

- [ ] DNS settings tab in Preferences
- [ ] DNS lookup tool in Dashboard: enter hostname, see all resolved records and which server responded
- [ ] DNS cache inspector: view and flush cache entries
- [ ] Show per-request DNS timing in request detail view

---

## Phase 4 — Proxy Protocols (weeks 25–34)

### Goals

Add upstream proxy protocol support so traffic can be forwarded through real proxy servers.

### Implementation approach

Each protocol is a SwiftNIO `ChannelHandler` that speaks the upstream protocol. The `ConnectionManager` selects the appropriate handler based on the matched policy.

```swift
protocol ProxyProtocolHandler: ChannelDuplexHandler {
    var config: ProxyConfig { get }
    func connect(to target: TargetEndpoint) async throws -> Channel
}
```

#### 4.1 SOCKS5 / SOCKS5-TLS

- [ ] SOCKS5 handshake (RFC 1928): version negotiation, auth, CONNECT command
- [ ] Username/password authentication (RFC 1929)
- [ ] SOCKS5-TLS: wrap connection in TLS before SOCKS5 handshake
- [ ] UDP ASSOCIATE support
- [ ] Unit tests: mock server, test all auth modes

#### 4.2 HTTP/HTTPS upstream proxy

- [ ] Plain HTTP proxy forwarding (non-CONNECT requests)
- [ ] HTTPS upstream (CONNECT to upstream proxy, then re-CONNECT to target)
- [ ] Proxy-Authorization header support

#### 4.3 Shadowsocks

- [ ] Cipher support: `chacha20-ietf-poly1305`, `aes-128-gcm`, `aes-256-gcm`
- [ ] AEAD encryption/decryption using BoringSSL or CryptoKit
- [ ] Shadowsocks 2022 Edition (newer format)
- [ ] Plugin support: `obfs`, `v2ray-plugin`
- [ ] Reference: [shadowsocks/shadowsocks-libev](https://github.com/shadowsocks/shadowsocks-libev)

#### 4.4 VMess

- [ ] VMess protocol v1 (AEAD)
- [ ] UUID-based authentication
- [ ] `auto` / `aes-128-gcm` / `chacha20-poly1305` encryption
- [ ] WebSocket and gRPC transport
- [ ] Reference: [sing-box VMess implementation](https://github.com/SagerNet/sing-box)

#### 4.5 Trojan

- [ ] Trojan-GFW protocol: TLS with SHA224 password hash header
- [ ] Trojan-Go WebSocket transport
- [ ] Reference: [trojan-go](https://github.com/p4gefau1t/trojan-go)

#### 4.6 WireGuard

- [ ] Compile `wireguard-go` as a static library
- [ ] Bridge via CGo → C → Swift using modulemap
- [ ] Create WireGuard tunnel interface, send/receive packets
- [ ] Configuration: private key, peer public key, endpoint, allowed IPs, DNS

```sh
# build-wireguard.sh
cd Vendors/wireguard-go
GOOS=darwin GOARCH=arm64 go build -buildmode=c-archive \
  -o ../../Frameworks/libwireguard-arm64.a ./...
```

- [ ] iOS: use `wireguard-apple` (official WireGuard iOS library)

#### 4.7 TUIC v5

- [ ] QUIC-based protocol using Apple Network framework (`NWConnection` with QUIC parameters)
- [ ] TUIC v5 handshake and multiplexing
- [ ] Reference: [EAimTY/tuic](https://github.com/EAimTY/tuic)

#### 4.8 Hysteria 2

- [ ] QUIC-based protocol with BBR congestion control
- [ ] Port existing Go implementation or use libhysteria C bindings
- [ ] Reference: [apernet/hysteria](https://github.com/apernet/hysteria)

#### 4.9 SSH tunnel

- [ ] Local-to-remote port forwarding via SSH
- [ ] `libssh2` via Swift bridge
- [ ] Key-based and password authentication

#### 4.10 Connection manager

- [ ] Route each connection to the correct protocol handler based on matched policy
- [ ] Connection pool per upstream proxy (reuse TCP connections where protocol allows)
- [ ] Latency measurement per connection for url-test groups
- [ ] Auto-reconnect on connection failure

---

## Phase 5 — macOS System-Level Traffic (weeks 35–44)

### Goals

Capture ALL device traffic regardless of whether apps respect the system proxy, using a TUN virtual network interface.

### Background

Enhanced mode creates a virtual network interface (`utun`). All IP traffic is routed through it. We implement a userspace TCP/IP stack (lwIP) to reassemble TCP streams and forward them through the proxy engine.

### Tasks

#### 5.1 utun interface setup

```swift
// TUNInterface.swift
import Darwin

class TUNInterface {
    private var fd: Int32 = -1
    private var ifName: String = ""

    func create() throws -> String {
        // Open /dev/utun0, /dev/utun1, etc.
        for unit in 0..<256 {
            fd = open("/dev/utun\(unit)", O_RDWR)
            if fd >= 0 {
                ifName = "utun\(unit)"
                try configure()
                return ifName
            }
        }
        throw TUNError.noAvailableInterface
    }

    private func configure() throws {
        // Set MTU, bring interface up
        // Assign IP 198.18.0.1, netmask 255.255.0.0
    }

    func read() throws -> Data { ... }
    func write(_ packet: Data) throws { ... }
}
```

- [ ] Open `utun` device via `socket(AF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)`
- [ ] Configure IP address (`198.18.0.1/15`) and MTU (1500)
- [ ] Bring interface up
- [ ] Add default route through the utun interface (`route add default -interface utun0`)
- [ ] Exclude proxy server IPs from TUN routing (avoid loop)

#### 5.2 lwIP integration

- [ ] Vendor lwIP 2.2.x source into `Vendors/lwip/`
- [ ] Create Swift modulemap bridge: `CLwIP`
- [ ] Initialize lwIP with custom netif (read/write callbacks bridge to utun fd)
- [ ] Configure lwIP: IP `198.18.0.2`, gateway `198.18.0.1`, DNS intercept
- [ ] Hook `tcp_accept` to get new inbound TCP connections from apps

```c
// lwip_bridge.h
void lwip_init_netif(write_callback_t write_cb, void* ctx);
void lwip_input_packet(const uint8_t* data, size_t len);
void lwip_set_tcp_accept_cb(tcp_accept_callback_t cb, void* ctx);
```

#### 5.3 Packet processor

- [ ] Read loop: read raw IP packets from utun fd in background thread
- [ ] Feed packets to lwIP: `lwip_input_packet(data, len)`
- [ ] lwIP callback: on new TCP connection, extract destination IP + port
- [ ] Fake-IP lookup: map destination IP → real hostname
- [ ] Hand off to rule engine + proxy engine as a new connection
- [ ] Write loop: lwIP sends outbound packets via write callback → write to utun fd

```swift
// PacketProcessor.swift
class PacketProcessor {
    func start(tunInterface: TUNInterface) {
        Task.detached(priority: .userInteractive) {
            while true {
                let packet = try tunInterface.read()
                CLwIP.inputPacket(packet)
            }
        }
    }

    func onNewTCPConnection(sourceIP: String, destIP: String, destPort: UInt16) {
        let hostname = fakeIPPool.lookup(ip: destIP) ?? destIP
        connectionManager.handle(hostname: hostname, port: destPort)
    }
}
```

#### 5.4 System proxy manager

- [ ] Set/unset system HTTP proxy: `networksetup -setwebproxy Wi-Fi 127.0.0.1 8888`
- [ ] Set/unset system HTTPS proxy: `networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 8888`
- [ ] Set/unset SOCKS proxy: `networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 8889`
- [ ] Handle multiple network interfaces (Wi-Fi, Ethernet, etc.)
- [ ] Restore proxy settings on app quit
- [ ] Detect active network interface changes and re-apply

#### 5.5 Enhanced mode toggle

- [ ] Preferences toggle: "Enhanced Mode" (TUN) vs "System Proxy only"
- [ ] Elevated privileges prompt for `route` and `ifconfig` commands (use `SMJobBless` or `AuthorizationExecuteWithPrivileges`)
- [ ] Helper tool (privileged daemon) for persistent route management
- [ ] Show interface name and IP in status bar tooltip

#### 5.6 Gateway mode

- [ ] Enable IP forwarding: `sysctl -w net.inet.ip.forwarding=1`
- [ ] Add `pf` rules to redirect incoming LAN traffic to local proxy port
- [ ] UI: show local IP, instructions for other devices to set gateway
- [ ] Cleanup: disable IP forwarding and remove pf rules on stop

#### 5.7 Process name matching (macOS)

- [ ] Use `proc_pidinfo` with `PROC_PIDTBSDINFO` to get process name from PID
- [ ] Use `lsof` or `proc_info` to map connection (local port) → PID
- [ ] Attach process name to each logged request
- [ ] Enable `PROCESS-NAME` rule matching

---

## Phase 6 — iOS Port (weeks 45–56)

### Goals

Port the app to iOS using `NEPacketTunnelProvider` for system-wide traffic interception.

### Prerequisites

- Apple Network Extension entitlement (apply during Phase 4 — takes weeks)
- WireGuard entitlement if shipping WireGuard on iOS

### Tasks

#### 6.1 Apple entitlement application

- [ ] Apply at [developer.apple.com](https://developer.apple.com) for:
  - `com.apple.developer.networking.networkextension` (packet-tunnel-provider)
  - `com.apple.developer.networking.networkextension` (content-filter-provider) — for process-level filtering
- [ ] Prepare justification: describe use case, security model, data handling
- [ ] Expect 2–6 week response time

#### 6.2 PacketTunnelProvider extension

```swift
// PacketTunnelProvider.swift
import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // Configure tunnel settings
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.2"], subnetMasks: ["255.255.0.0"])
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.1"])
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { error in
            if let error { completionHandler(error); return }
            self.startPacketLoop()
            completionHandler(nil)
        }
    }

    private func startPacketLoop() {
        // Read packets from packetFlow, feed to lwIP
        // lwIP output → write back to packetFlow
        packetFlow.readPacketObjects { packets in
            for packet in packets {
                CLwIP.inputPacket(packet.data)
            }
            self.startPacketLoop() // recurse
        }
    }
}
```

- [ ] Configure `NEPacketTunnelNetworkSettings` with virtual IP, default route, DNS intercept
- [ ] Packet read loop: `packetFlow.readPacketObjects`
- [ ] Feed packets to lwIP (same C bridge as macOS)
- [ ] lwIP TCP accept callback → CoreProxy rule engine (shared package)
- [ ] Write loop: lwIP sends packets via callback → `packetFlow.writePacketObjects`

#### 6.3 IPC between app and extension

- [ ] Use `NETunnelProviderSession` to communicate from app → extension
- [ ] Send profile updates via `sendProviderMessage`
- [ ] Extension sends log events back to app via `notifyDataRecord`
- [ ] Alternatively: share data via App Groups (`UserDefaults(suiteName:)` and shared SQLite)

#### 6.4 iOS Dashboard

- [ ] Same SwiftUI views as macOS, adapted for iPhone/iPad layout
- [ ] Request list as full-screen view
- [ ] Filter sheet (bottom sheet on iPhone)
- [ ] Remote Dashboard: allow Mac to connect to iOS device dashboard over Wi-Fi or USB
  - iOS: start WebSocket server in tunnel extension
  - Mac: discover via Bonjour or manual IP entry
  - USB: use `usbmuxd` protocol for USB connection

#### 6.5 iOS-specific features

- [ ] Works on cellular networks (automatic, no extra config needed via NEPacketTunnel)
- [ ] Certificate installation via `SecCertificateAddToKeychain` → Settings prompt
- [ ] Profile import via share sheet (`.conf` file)
- [ ] Shortcuts integration (enable/disable proxy via Shortcuts)
- [ ] Widget: proxy status, connection count

#### 6.6 App Store submission

- [ ] Non-China App Store region only (Network Extension not available in China)
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`)
- [ ] App Review: prepare detailed justification for Network Extension usage
- [ ] One-time purchase pricing model

---

## Phase 7 — Scripting Engine (weeks 57–64)

### Goals

Expose a JavaScript API that lets users write scripts to modify requests, responses, DNS, and automate workflows.

### Tasks

#### 7.1 JavaScriptCore integration

```swift
// ScriptEngine.swift
import JavaScriptCore

class ScriptEngine {
    private let context = JSContext()!

    func setup() {
        // Inject $httpClient
        let httpClient = HTTPClientBridge()
        context.setObject(httpClient, forKeyedSubscript: "$httpClient" as NSString)

        // Inject $notification
        let notification = NotificationBridge()
        context.setObject(notification, forKeyedSubscript: "$notification" as NSString)

        // Inject $prefs
        let prefs = PrefsBridge()
        context.setObject(prefs, forKeyedSubscript: "$prefs" as NSString)

        // $done() — resolves the script
        context.setObject(unsafeBitCast(doneCallback, to: AnyObject.self),
                          forKeyedSubscript: "$done" as NSString)
    }

    func evaluateRequestScript(_ script: String, request: ProxyRequest) async throws -> ScriptResult {
        injectRequest(request)
        context.evaluateScript(script)
        return awaitDone()
    }
}
```

#### 7.2 Script API surface

```javascript
// Available in request scripts:
$request.url          // string — full URL
$request.method       // string — GET, POST, etc.
$request.headers      // object — header name → value
$request.body         // string — request body (decoded)

// Available in response scripts:
$response.statusCode  // number
$response.headers     // object
$response.body        // string

// Modify and resolve:
$done({
  headers: { "X-Custom": "value" },
  body: "modified body"
});

// Block request:
$done({ response: { statusCode: 403, body: "Blocked" } });

// HTTP client (outbound requests from script):
$httpClient.get({ url: "https://api.example.com/data" }, function(error, resp, data) {
  $done({ body: data });
});

// Persistent storage:
$prefs.setValueForKey("token", "my-api-key");
const token = $prefs.valueForKey("token");

// Notifications:
$notification.post("Script fired", "Request modified", "Details here");
```

#### 7.3 Script hook points

- [ ] `http-request` — fires before request is sent; can modify or block
- [ ] `http-response` — fires after response received; can modify body/headers
- [ ] `dns` — custom DNS resolution logic
- [ ] `rule` — custom rule evaluation
- [ ] `network-changed` — fires when network interface changes
- [ ] `cron` — periodic execution (crontab-style schedule)

#### 7.4 Script scheduler

- [ ] Parse cron expressions (minute, hour, day, etc.)
- [ ] Background `Timer`-based scheduler
- [ ] Execute scripts in isolated JSContext per invocation (no state leak)
- [ ] Timeout: kill scripts running >30 seconds

#### 7.5 Script manager UI

- [ ] Script list: name, type (request/response/cron), enabled toggle
- [ ] Inline code editor (syntax highlighted, monospace)
- [ ] Console output panel: `console.log()` output + errors
- [ ] Test button: run script against a recent request from the log
- [ ] Import scripts from URL

---

## Phase 8 — Polish & Advanced Features (weeks 65–80)

### Goals

Complete remaining Surge features, harden the product, and prepare for public launch.

### Tasks

#### 8.1 Surge Ponte — mesh networking

Surge Ponte is a decentralized, encrypted mesh that lets Surge devices route through each other. This is the most complex feature.

- [ ] End-to-end encrypted P2P connections (use Noise protocol or WireGuard as transport)
- [ ] Relay server for NAT traversal (STUN/TURN-like)
- [ ] Multi-path routing: try multiple paths simultaneously, use fastest
- [ ] Auto-failover: seamless switch when a path drops
- [ ] Self-developed dynamic switching algorithm
- [ ] Device discovery: iCloud-based peer discovery (use CloudKit)

#### 8.2 HTTP rewriting

- [ ] URL rewrite: `^https://example.com/old https://example.com/new 302`
- [ ] URL reject: `^https://ads.example.com`
- [ ] Header rewrite (request): add/remove/modify headers
- [ ] Header rewrite (response): add/remove/modify headers
- [ ] Body rewrite: regex replace in response body
- [ ] Mock response: serve static body for matched URL

#### 8.3 HTTP API

Expose a local REST API for external tooling and automation:

```
GET  /v1/requests          — recent request log
GET  /v1/requests/:id      — request detail
GET  /v1/policies          — list policies and current selection
POST /v1/policies/:name    — select a policy
GET  /v1/proxies           — proxy list with latency
POST /v1/test              — trigger latency test
GET  /v1/dns/cache         — DNS cache contents
DELETE /v1/dns/cache       — flush DNS cache
POST /v1/reload            — reload profile
GET  /v1/traffic           — current bandwidth stats
```

- [ ] HTTP server on `127.0.0.1:9090` (configurable)
- [ ] Optional Bearer token authentication
- [ ] Dashboard uses same API (replaces WebSocket for state queries)

#### 8.4 URL scheme

```
surgeapp://start
surgeapp://stop
surgeapp://reload
surgeapp://policy?name=Proxy&policy=US-Server
surgeapp://install-profile?url=https://example.com/profile.conf
```

#### 8.5 Metered network mode (macOS)

- [ ] Use `NEFilterDataProvider` to control which processes can access internet
- [ ] Allowlist-based: only permitted processes get through
- [ ] UI: process list with allow/block toggles
- [ ] Useful when using a mobile hotspot

#### 8.6 Advanced DNS features

- [ ] DNS hijacking: intercept all DNS queries on port 53 (even from apps using hardcoded DNS)
- [ ] DNS-over-QUIC support
- [ ] Response Policy Zone (RPZ) support
- [ ] EDNS Client Subnet suppression

#### 8.7 tvOS target (bonus)

- [ ] Port iOS app to tvOS
- [ ] Apple TV as network gateway for other devices
- [ ] Remote profile management from iPhone

#### 8.8 Performance hardening

- [ ] Profile with Instruments: identify hot paths in packet processing loop
- [ ] Zero-copy packet handling where possible
- [ ] Reduce allocation in per-request hot path
- [ ] Benchmark: handle 10,000 concurrent connections with <5ms overhead

#### 8.9 Documentation

- [ ] In-app help: link to online manual
- [ ] Config file format reference (complete `.conf` spec)
- [ ] Script API reference with examples
- [ ] Quick Start guide
- [ ] Video walkthroughs for common setups

---

## 15. Data Models

### Profile (stored as `.conf` file + parsed in-memory)

```swift
struct GeneralConfig: Codable {
    var logLevel: LogLevel         // verbose, info, warning, error
    var listenInterface: String    // 127.0.0.1
    var httpPort: Int              // 8888
    var socksPort: Int             // 8889
    var enhancedMode: Bool
    var excludeSimpleHostnames: Bool
    var dnsServer: [String]
    var skipProxy: [String]        // bypass list for system proxy
    var alwaysRealIPHosts: [String]
    var testURL: String            // connectivity test URL
    var internetTestURL: String
}

struct MITMConfig: Codable {
    var enabled: Bool
    var hostnames: [String]        // e.g. *.example.com
    var clientSourceAddress: String?
    var caCertificate: String?     // base64 encoded PEM (stored separately)
}

struct ScriptConfig: Codable {
    var name: String
    var type: ScriptType           // http-request, http-response, cron, dns, rule, event
    var pattern: String?           // URL pattern (for http-* types)
    var script: String             // inline JS or path to .js file
    var cronExpression: String?
    var binaryBodyMode: Bool
    var timeout: Int               // seconds
    var argument: String?
}
```

### Request log entry (stored in SQLite)

```swift
struct RequestLogEntry: Codable {
    var id: UUID
    var timestamp: Date
    var method: String
    var url: URL
    var host: String
    var port: Int
    var statusCode: Int?
    var requestHeaders: [String: String]
    var responseHeaders: [String: String]
    var requestBodySize: Int
    var responseBodySize: Int
    var matchedRule: String?
    var appliedPolicy: String?
    var processName: String?
    var remotePeerAddress: String?
    var dnsLookupMs: Double
    var tcpConnectMs: Double
    var tlsHandshakeMs: Double
    var ttfbMs: Double             // time to first byte
    var totalMs: Double
    var notes: String?
}
```

---

## 16. Config File Format

The config file is a Surge-compatible `.conf` file. Example:

```ini
[General]
log-level = notify
http-listen = 127.0.0.1:8888
socks5-listen = 127.0.0.1:8889
enhanced-mode = true
exclude-simple-hostnames = true
dns-server = 8.8.8.8, 8.8.4.4
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, localhost, *.local
tun-excluded-routes = 192.168.0.0/16, 10.0.0.0/8
internet-test-url = http://connectivitycheck.gstatic.com/generate_204
proxy-test-url = http://cp.cloudflare.com/generate_204
test-timeout = 5

[Proxy]
US-Server = vmess, us.example.com, 443, username=uuid-here, tls=true, ws=true
JP-Server = trojan, jp.example.com, 443, password=secret, tls=true
SG-SOCKS = socks5, sg.example.com, 1080, username=user, password=pass
Direct = direct

[Proxy Group]
Auto = url-test, US-Server, JP-Server, SG-SOCKS, url=http://cp.cloudflare.com/generate_204, interval=300, tolerance=50
Proxy = select, Auto, US-Server, JP-Server, SG-SOCKS, Direct

[Rule]
DOMAIN-SUFFIX,google.com,Proxy
DOMAIN-SUFFIX,github.com,Proxy
DOMAIN-KEYWORD,facebook,Proxy
GEOIP,CN,Direct
IP-CIDR,192.168.0.0/16,Direct,no-resolve
FINAL,Proxy

[Host]
*.google.cn = server:8.8.8.8
testflight.apple.com = server:8.8.8.8
mtalk.google.com = 108.177.125.188
localhost = 127.0.0.1

[DNS]
no-system = false
prefer-doh = true
doh-server = https://dns.cloudflare.com/dns-query, https://dns.google/dns-query
listen = 127.0.0.1:53
fake-ip-range = 198.18.0.1/16
fake-ip-filter = *.lan, *.local, localhost

[MITM]
hostname = *.google.com, *.apple.com
ca-passphrase = MyCAPassword
ca-p12 = (base64 encoded PKCS#12)

[Script]
MyRequestScript = type=http-request, pattern=^https://api.example.com, script-path=myscript.js, max-size=131072, debug=false

[URL Rewrite]
^https://example.com/redirect https://example.com/new 302
^https://ads.example.com - reject

[Header Rewrite]
^https://example.com header-replace User-Agent "MyApp/1.0"
```

---

## 17. Testing Strategy

### Unit tests (XCTest + Swift Testing)

- [ ] `RuleEngineTests` — test every rule type with positive/negative cases
- [ ] `DNSTests` — resolver, cache, fake-IP pool, local mapping
- [ ] `MITMTests` — cert generation, cert chain validation, TLS intercept
- [ ] `ProtocolTests` — mock upstream servers for each proxy protocol
- [ ] `ProfileParserTests` — round-trip parse/serialize for all config options
- [ ] `ScriptEngineTests` — test each JS API method, error handling, timeouts

### Integration tests

- [ ] End-to-end HTTP request through proxy → rule match → direct connection
- [ ] End-to-end HTTPS request with MITM → decrypted body visible in log
- [ ] DNS resolution through custom resolver
- [ ] Fake-IP assignment and TCP connection recovery
- [ ] Proxy protocol integration: spin up real Shadowsocks/SOCKS5 server in Docker, run traffic through it

### Performance benchmarks

- [ ] Rule engine: benchmark matching 10,000 rules against 100,000 hostnames
- [ ] Cert generation: measure per-host cert generation time (target: <5ms cached, <20ms fresh)
- [ ] DNS cache: benchmark lookup throughput (target: >500,000 lookups/sec)
- [ ] Packet processing: measure overhead added to TCP throughput (target: <5%)

### Manual QA checklist (per release)

- [ ] Browser traffic intercepted and logged correctly
- [ ] HTTPS decryption working (check request inspector shows body)
- [ ] Rule matching: test each rule type with known-matching and non-matching requests
- [ ] All proxy protocols: verify connection succeeds through a real server
- [ ] DNS: verify DoH, DoT, fake-IP mode all work
- [ ] Script: run a request-modifying script and verify body is changed
- [ ] TUN mode: verify apps that hardcode DNS or ignore system proxy are still captured
- [ ] iOS: verify cellular traffic captured, remote dashboard works over USB

---

## 18. Open Source References

| Project | Language | What to learn from it |
|---|---|---|
| [sing-box](https://github.com/SagerNet/sing-box) | Go | All proxy protocol implementations; clean interface design |
| [clash](https://github.com/Dreamacro/clash) | Go | Rule engine, policy groups, DNS engine |
| [mitmproxy](https://github.com/mitmproxy/mitmproxy) | Python | Best-in-class MITM implementation; read `proxy/` module |
| [lwIP](https://savannah.nongnu.org/projects/lwip/) | C | Userspace TCP/IP stack; read `src/core/tcp.c` |
| [wireguard-go](https://git.zx2c4.com/wireguard-go) | Go | Official WireGuard implementation |
| [wireguard-apple](https://git.zx2c4.com/wireguard-apple) | Swift | WireGuard for iOS/macOS using NetworkExtension |
| [SwiftNIO](https://github.com/apple/swift-nio) | Swift | Async I/O framework; study `NIOHTTP1`, `NIOSSL` |
| [BoringSSL](https://boringssl.googlesource.com/boringssl/) | C | TLS implementation used by Chrome and many Apple apps |
| [MaxMind GeoIP2](https://github.com/maxmind/MaxMind-DB-Reader-swift) | Swift | GeoIP database reader |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | Swift | SQLite for Swift — request log storage |
| [mmdb-swift](https://github.com/lexrus/MMDB-Swift) | Swift | MaxMind DB reader in Swift |

---

## 19. Apple Entitlements & App Store

### Required entitlements

| Entitlement | Purpose | Where to apply |
|---|---|---|
| `com.apple.developer.networking.networkextension` (packet-tunnel-provider) | iOS/macOS TUN interception | Apple Developer portal — requires justification |
| `com.apple.developer.networking.networkextension` (content-filter-provider) | Per-process filtering on macOS | Same as above |
| `com.apple.security.network.client` | Outbound network connections | Standard, no review required |
| `com.apple.security.network.server` | Listen on ports (macOS) | Standard, no review required |

### Application process

1. Log into [developer.apple.com/account](https://developer.apple.com/account)
2. Go to Certificates, Identifiers & Profiles → Identifiers → your App ID
3. Enable Network Extensions capability
4. Submit justification form — describe: what traffic you capture, how data is handled, security model, user controls
5. Apple reviews in 2–6 weeks
6. Once approved, add entitlement to `.entitlements` file and provisioning profile

### App Review guidelines

- Clearly disclose traffic interception in App Store description and privacy policy
- Certificate trust must be explicitly user-initiated (no silent CA installation)
- No data exfiltration — all traffic stays on device or goes to user-configured proxies
- Prepare a demo video showing the app working correctly
- Have a support URL and privacy policy URL ready

### macOS distribution

- Distribute via Mac App Store (restricted features due to sandbox) or
- Direct download + Developer ID notarization (recommended — avoids App Store sandboxing restrictions that conflict with TUN mode)
- Notarize with `xcrun notarytool submit` and staple ticket

---

## 20. Timeline Summary

| Phase | Duration | End of phase milestone |
|---|---|---|
| 0 — Foundation | 4 weeks | Project setup, data models, config parser, CI |
| 1 — HTTP proxy + Dashboard | 8 weeks | Working MITM proxy; browser traffic visible in dashboard |
| 2 — Rule engine + Profiles | 6 weeks | Full rule matching; profile import/export |
| 3 — DNS engine | 6 weeks | Fake-IP mode; DoH/DoT; DNS inspector |
| 4 — Proxy protocols | 10 weeks | WireGuard, VMess, Shadowsocks, Trojan, TUIC all working |
| 5 — macOS TUN mode | 10 weeks | All apps intercepted regardless of proxy support; gateway mode |
| 6 — iOS port | 12 weeks | iOS app submitted to App Store |
| 7 — Scripting | 8 weeks | JS API complete; script editor UI |
| 8 — Polish | 16 weeks | v1.0 shipped |
| **Total** | **~80 weeks (~18–20 months)** | **Production v1.0** |

### Team recommendation

| Role | Count | Notes |
|---|---|---|
| iOS/macOS systems engineer | 1–2 | Deep networking + TLS + NetworkExtension experience |
| Swift/SwiftNIO engineer | 1 | Proxy engine, protocol implementations |
| UI/UX engineer | 1 | SwiftUI dashboard, profile editor |
| **Total** | **3–4 engineers** | Solo feasible but ~3 years |

### Budget estimate

| Item | Cost |
|---|---|
| Apple Developer Program | $99/year |
| MaxMind GeoLite2 | Free (CC BY-SA 4.0) or GeoIP2 Commercial ($?) |
| Code signing certificate | Included in Developer Program |
| CI/CD (GitHub Actions) | Free tier sufficient |
| Notarization | Included in Developer Program |
| **Engineering (3 engineers × 18 months)** | **The primary cost** |

---

*Last updated: June 2026*
*Version: 1.0*
