#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
capnp="$prefix/bin/capnp"
tool="$root/.build/debug/capnpc-swift"
fixtures="$root/Tests/CapnProtoCompilerTests/Fixtures"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$root"
swift build --product capnpc-swift

inputs="$work/schema inputs"
first="$work/first output"
second="$work/second output"
mkdir -p "$inputs" "$first" "$second"
cp "$fixtures"/*.capnp "$inputs/"

generate() {
  local destination="$1"
  "$capnp" compile -o"$tool:$destination" --src-prefix="$inputs" \
    "$inputs/keywords.capnp" "$inputs/import-user.capnp"
}

generate "$first"
generate "$second"
diff -ru "$first" "$second"

consumer="$work/clean consumer"
mkdir -p "$consumer/Sources/Generated"
cp "$first"/*.swift "$consumer/Sources/Generated/"
cat > "$consumer/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GeneratedConsumer",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Generated", targets: ["Generated"])],
    dependencies: [.package(path: "$root")],
    targets: [
        .target(
            name: "Generated",
            dependencies: [.product(name: "CapnProto", package: "swift-capnproto")])
    ],
    swiftLanguageModes: [.v6]
)
EOF
swift build --package-path "$consumer"

echo "Swift generation is deterministic and compiles from paths containing spaces"
