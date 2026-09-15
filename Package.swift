// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-capnproto",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "CapnProto", targets: ["CapnProto"]),
        .library(name: "CapnProtoSchema", targets: ["CapnProtoSchema"]),
        .library(name: "CapnProtoRPC", targets: ["CapnProtoRPC"]),
        .library(name: "CapnProtoNIO", targets: ["CapnProtoNIO"]),
        .library(name: "CapnProtoCompiler", targets: ["CapnProtoCompiler"]),
        .executable(name: "capnpc-swift", targets: ["capnpc-swift"]),
        .executable(name: "capnp-swift", targets: ["capnp-swift"]),
        .executable(name: "capnp-test-swift", targets: ["capnp-test-swift"]),
        .plugin(name: "CapnProtoPlugin", targets: ["CapnProtoPlugin"]),
    ],
    targets: [
        .target(name: "CapnProto"),
        .target(name: "CapnProtoSchema", dependencies: ["CapnProto"]),
        .target(name: "CapnProtoRPC", dependencies: ["CapnProto", "CapnProtoSchema"]),
        .target(name: "CapnProtoNIO", dependencies: ["CapnProtoRPC"]),
        .target(name: "CapnProtoCompiler", dependencies: ["CapnProto", "CapnProtoSchema"]),
        .executableTarget(name: "capnpc-swift", dependencies: ["CapnProtoCompiler"]),
        .executableTarget(name: "capnp-swift", dependencies: ["CapnProtoCompiler"]),
        .executableTarget(name: "capnp-test-swift", dependencies: ["CapnProto"]),
        .plugin(name: "CapnProtoPlugin", capability: .buildTool()),
        .testTarget(name: "CapnProtoTests", dependencies: ["CapnProto"]),
        .testTarget(name: "CapnProtoSchemaTests", dependencies: ["CapnProtoSchema"]),
        .testTarget(name: "CapnProtoRPCTests", dependencies: ["CapnProtoRPC"]),
        .testTarget(name: "CapnProtoNIOTests", dependencies: ["CapnProtoNIO"]),
        .testTarget(name: "CapnProtoCompilerTests", dependencies: ["CapnProtoCompiler"]),
    ],
    swiftLanguageModes: [.v6]
)
