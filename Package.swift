// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "DevScope",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "DevScopeCore", targets: ["DevScopeCore"]),
    .executable(name: "DevScope", targets: ["DevScope"])
  ],
  targets: [
    .target(name: "DevScopeCore"),
    .executableTarget(
      name: "DevScope",
      dependencies: ["DevScopeCore"]
    ),
    .testTarget(
      name: "DevScopeCoreTests",
      dependencies: ["DevScopeCore"]
    ),
    .testTarget(
      name: "DevScopeTests",
      dependencies: ["DevScope", "DevScopeCore"]
    )
  ]
)
