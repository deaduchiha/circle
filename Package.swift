// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "circle",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "CoreProxy", targets: ["CoreProxy"]),
    .executable(name: "circle", targets: ["circle"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
  ],
  targets: [
    .target(
      name: "CoreProxy",
      dependencies: [
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [
        .process("../../Resources")
      ]
    ),
    .executableTarget(
      name: "circle",
      dependencies: ["CoreProxy"]
    ),
    .testTarget(
      name: "CoreProxyTests",
      dependencies: ["CoreProxy"]
    ),
  ]
)
