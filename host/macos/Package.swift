// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OrangeHost", platforms: [.macOS(.v13)], products: [
    .executable(name: "orange-host", targets: ["OrangeHost"]),
], targets: [
    .target(name: "HostProtocol"),
    .executableTarget(name: "OrangeHost", dependencies: ["HostProtocol"]),
    .testTarget(name: "HostProtocolTests", dependencies: ["HostProtocol"]),
])
