// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-capnproto",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
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
        .executable(name: "capnp-rpc-interop-swift", targets: ["capnp-rpc-interop-swift"]),
        .executable(name: "capnp-rpc-soak", targets: ["capnp-rpc-soak"]),
        .executable(name: "capnp-example-address-book", targets: ["AddressBookExample"]),
        .executable(name: "capnp-example-evolution", targets: ["SchemaEvolutionExample"]),
        .executable(name: "capnp-example-calculator", targets: ["CalculatorExample"]),
        .executable(name: "capnp-example-pipeline", targets: ["PipelinedRPCExample"]),
        .plugin(name: "CapnProtoPlugin", targets: ["CapnProtoPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0")
    ],
    targets: [
        .target(name: "CapnProto"),
        .target(name: "CapnProtoSchema", dependencies: ["CapnProto"]),
        .target(name: "CapnProtoRPC", dependencies: ["CapnProto", "CapnProtoSchema"]),
        .target(
            name: "CapnProtoNIO",
            dependencies: [
                "CapnProtoRPC",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
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
            dependencies: ["CapnProto", "CapnProtoSchema"],
            path: "Tests/Support"
        ),
        .executableTarget(name: "capnpc-swift", dependencies: ["CapnProtoCompiler"]),
        .executableTarget(name: "capnp-swift", dependencies: ["CapnProtoCompiler"]),
        .executableTarget(
            name: "capnp-test-swift", dependencies: ["CapnProto", "CapnProtoConformance"]),
        .executableTarget(
            name: "capnp-rpc-interop-swift",
            dependencies: ["CapnProto", "CapnProtoRPC", "CapnProtoNIO"]),
        .executableTarget(
            name: "capnp-rpc-soak", dependencies: ["CapnProto", "CapnProtoRPC"]),
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
            name: "capnp-fuzz-schema",
            dependencies: ["CapnProtoTestSupport", "CapnProtoCompiler"],
            path: "Fuzz/Schema"
        ),
        .executableTarget(
            name: "capnp-benchmark",
            dependencies: ["CapnProto"],
            path: "Benchmarks",
            exclude: ["BASELINES.tsv", "README.md", "comparison.jsonl"]
        ),
        .executableTarget(
            name: "AddressBookExample", dependencies: ["CapnProto"],
            path: "Examples/AddressBook", exclude: ["addressbook.capnp"]),
        .executableTarget(
            name: "SchemaEvolutionExample", dependencies: ["CapnProto"],
            path: "Examples/SchemaEvolution"),
        .executableTarget(
            name: "CalculatorExample", dependencies: ["CapnProto", "CapnProtoRPC"],
            path: "Examples/Calculator"),
        .executableTarget(
            name: "PipelinedRPCExample", dependencies: ["CapnProto", "CapnProtoRPC"],
            path: "Examples/PipelinedRPC"),
        .plugin(
            name: "CapnProtoPlugin", capability: .buildTool(),
            dependencies: ["capnp-swift"]),
        .testTarget(
            name: "CapnProtoTests", dependencies: ["CapnProto", "CapnProtoTestSupport"]),
        .testTarget(
            name: "CapnProtoSchemaTests",
            dependencies: ["CapnProtoSchema"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CapnProtoRPCTests", dependencies: ["CapnProto", "CapnProtoRPC"]),
        .testTarget(
            name: "CapnProtoNIOTests",
            dependencies: ["CapnProto", "CapnProtoRPC", "CapnProtoNIO"]),
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
