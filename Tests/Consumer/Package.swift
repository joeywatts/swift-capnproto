// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReleaseConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "swift-capnproto", path: "../..")],
    targets: [
        .executableTarget(
            name: "ReleaseConsumer",
            dependencies: [.product(name: "CapnProto", package: "swift-capnproto")])
    ],
    swiftLanguageModes: [.v6]
)
