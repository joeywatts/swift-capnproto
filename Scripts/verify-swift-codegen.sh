#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/Tests/Upstream/BASELINES"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
capnp="$prefix/bin/capnp"
tool="$root/.build/debug/capnpc-swift"
fixtures="$root/Tests/CapnProtoCompilerTests/Fixtures"
stock="$root/Tests/Conformance/capnp_test"
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
  "$capnp" compile -o"$tool:$destination" --src-prefix="$inputs" \
    "$inputs/import-base.capnp"
  "$capnp" compile -o"$tool:$destination" --src-prefix="$stock" \
    "$stock/test.capnp"
}

generate "$first"
generate "$second"
diff -ru "$first" "$second"
swift format --in-place --configuration "$root/.swift-format" "$first/test.capnp.swift"
diff -u "$root/Tests/Generated/CapnpTest/test.capnp.swift" "$first/test.capnp.swift"

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

upstream="$root/.build/reference-capnp/$CAPNPROTO_REV/source/c++/src/capnp"
upstream_import_root="$(dirname "$upstream")"
upstream_first="$work/upstream first"
upstream_second="$work/upstream second"
mkdir -p "$upstream_first" "$upstream_second"
"$capnp" compile --no-standard-import -I"$upstream_import_root" \
  -o"$tool:$upstream_first" --src-prefix="$upstream" "$upstream/test.capnp"
"$capnp" compile --no-standard-import -I"$upstream_import_root" \
  -o"$tool:$upstream_second" --src-prefix="$upstream" "$upstream/test.capnp"
diff -ru "$upstream_first" "$upstream_second"
swiftc -typecheck -swift-version 6 -I "$root/.build/debug/Modules" \
  "$upstream_first/test.capnp.swift"

echo "local and upstream Swift generation is deterministic and compiles with strict concurrency"
