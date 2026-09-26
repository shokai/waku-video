// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "VideoClip",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "VideoClip", targets: ["VideoClip"])
  ],
  targets: [
    .target(name: "VideoClipCore"),
    .executableTarget(name: "VideoClip", dependencies: ["VideoClipCore"]),
    .testTarget(name: "VideoClipCoreTests", dependencies: ["VideoClipCore"]),
  ]
)
