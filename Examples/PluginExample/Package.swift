// swift-tools-version: 6.0

import Foundation
import PackageDescription

let swiftCapnProtoPath = ProcessInfo.processInfo.environment["SWIFT_CAPNPROTO_PATH"] ?? "../.."

let package = Package(
    name: "PluginExample",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: swiftCapnProtoPath)],
    targets: [
        .executableTarget(
            name: "PluginExample",
            dependencies: [.product(name: "CapnProto", package: "swift-capnproto")],
            exclude: [".capnp-swift.json", "greeting.capnp", "Schemas"],
            plugins: [.plugin(name: "CapnProtoPlugin", package: "swift-capnproto")]
        )
    ],
    swiftLanguageModes: [.v6]
)
