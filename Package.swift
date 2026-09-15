// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-capnproto",
    platforms: [
        .macOS(.v13)
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
        .target(
            name: "CapnProtoConformance",
            dependencies: ["CapnProto"],
            path: "Tests/Generated/CapnpTest"
        ),
        .target(
            name: "CapnProtoGeneratedFixtures",
            dependencies: ["CapnProto", "CapnProtoRPC"],
            path: "Tests/Generated/CompilerFixtures"
        ),
        .target(
            name: "CapnProtoTestSupport",
            dependencies: ["CapnProto"],
            path: "Tests/Support"
        ),
        .executableTarget(name: "capnpc-swift", dependencies: ["CapnProtoCompiler"]),
        .executableTarget(name: "capnp-swift", dependencies: ["CapnProtoCompiler"]),
        .executableTarget(
            name: "capnp-test-swift", dependencies: ["CapnProto", "CapnProtoConformance"]),
        .executableTarget(
            name: "capnp-fuzz-message",
            dependencies: ["CapnProtoTestSupport"],
            path: "Fuzz/Message"
        ),
        .executableTarget(
            name: "capnp-fuzz-packed",
            dependencies: ["CapnProtoTestSupport"],
            path: "Fuzz/Packed"
        ),
        .executableTarget(
            name: "capnp-benchmark",
            dependencies: ["CapnProto"],
            path: "Benchmarks"
        ),
        .plugin(name: "CapnProtoPlugin", capability: .buildTool()),
        .testTarget(
            name: "CapnProtoTests", dependencies: ["CapnProto", "CapnProtoTestSupport"]),
        .testTarget(
            name: "CapnProtoSchemaTests",
            dependencies: ["CapnProtoSchema"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CapnProtoRPCTests", dependencies: ["CapnProtoRPC"]),
        .testTarget(name: "CapnProtoNIOTests", dependencies: ["CapnProtoNIO"]),
        .testTarget(
            name: "CapnProtoCompilerTests",
            dependencies: [
                "CapnProtoCompiler", "CapnProtoConformance", "CapnProtoGeneratedFixtures",
                "CapnProtoRPC",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CapnProtoTestSupportTests", dependencies: ["CapnProtoTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
