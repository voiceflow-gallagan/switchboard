// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SwitchboardCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SwitchboardCore", targets: ["SwitchboardCore"])
  ],
  targets: [
    .target(name: "SwitchboardCore"),
    .testTarget(
      name: "SwitchboardCoreTests",
      dependencies: ["SwitchboardCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
