// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OrangeHost", platforms: [.macOS(.v13)], products: [
    .executable(name: "orange-host", targets: ["OrangeHost"]),
], targets: [
    .target(name: "HostProtocol"),
    .target(name: "HostHardware", dependencies: ["HostProtocol"]),
    .executableTarget(name: "OrangeHost", dependencies: ["HostProtocol", "HostHardware"]),
    .testTarget(name: "HostProtocolTests", dependencies: ["HostProtocol"]),
])
