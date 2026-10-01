// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThoughtDrop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ThoughtDrop", targets: ["ThoughtDrop"]),
               .executable(name: "ThoughtDropTools", targets: ["ThoughtDropTools"])],
    targets: [
        .target(name: "ThoughtCore"),
        .executableTarget(name: "ThoughtDrop", dependencies: ["ThoughtCore"]),
        .executableTarget(name: "ThoughtDropTools", dependencies: ["ThoughtCore"]),
        .testTarget(name: "ThoughtCoreTests", dependencies: ["ThoughtCore"])
    ]
)
