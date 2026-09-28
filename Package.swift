// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WakuVideo",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "WakuVideo", targets: ["WakuVideo"])
  ],
  targets: [
    .target(name: "WakuVideoCore"),
    .executableTarget(name: "WakuVideo", dependencies: ["WakuVideoCore"]),
    .testTarget(name: "WakuVideoCoreTests", dependencies: ["WakuVideoCore"]),
  ]
)
