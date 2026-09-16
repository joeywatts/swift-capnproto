#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/Tests/Upstream/BASELINES"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
capnp="$prefix/bin/capnp"
tool="$root/.build/debug/capnpc-swift"
native="$root/.build/debug/capnp-swift"
fixtures="$root/Tests/CapnProtoCompilerTests/Fixtures"
stock="$root/Tests/Conformance/capnp_test"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc=(swiftc)
if [[ "$(uname -s)" == "Darwin" ]]; then
  swiftc+=(-sdk "$(xcrun --sdk macosx --show-sdk-path)")
fi

cd "$root"
swift build --product capnpc-swift
swift build --product capnp-swift
swift build --target CapnProtoRPC

inputs="$work/schema inputs"
first="$work/first output"
second="$work/second output"
mkdir -p "$inputs" "$first" "$second"
cp "$fixtures"/*.capnp "$inputs/"

generate() {
  local destination="$1"
  "$capnp" compile -o"$tool:$destination" --src-prefix="$inputs" \
    "$inputs/keywords.capnp" "$inputs/import-user.capnp" "$inputs/advanced.capnp" \
    "$inputs/interfaces.capnp"
  "$capnp" compile -o"$tool:$destination" --src-prefix="$inputs" \
    "$inputs/import-base.capnp"
  "$capnp" compile -o"$tool:$destination" --src-prefix="$stock" \
    "$stock/test.capnp"
}

generate "$first"
generate "$second"
diff -ru "$first" "$second"
native_local="$work/native local"
mkdir -p "$native_local"
"$native" compile -I"$inputs" --src-prefix "$inputs" -o "$native_local" \
  "$inputs/keywords.capnp" "$inputs/import-user.capnp" "$inputs/import-base.capnp" \
  "$inputs/advanced.capnp" "$inputs/interfaces.capnp"
for generated in keywords.capnp.swift import-user.capnp.swift import-base.capnp.swift \
  advanced.capnp.swift interfaces.capnp.swift; do
  diff -u "$first/$generated" "$native_local/$generated"
done
mkdir -p "$work/ir local out"
"$capnp" compile -o- --src-prefix="$inputs" "$inputs/advanced.capnp" > "$work/ir-local-cpp.bin"
"$native" compile -I"$inputs" --src-prefix "$inputs" -o "$work/ir local out" \
  --request-output "$work/ir-local-native.bin" "$inputs/advanced.capnp"
"$native" normalize-request "$work/ir-local-cpp.bin" > "$work/ir-local-cpp.txt"
"$native" normalize-request "$work/ir-local-native.bin" > "$work/ir-local-native.txt"
diff -u "$work/ir-local-cpp.txt" "$work/ir-local-native.txt"
for version in v1 v2; do
  "$capnp" compile -o- --src-prefix="$inputs" "$inputs/evolution-$version.capnp" \
    > "$work/ir-evolution-$version-cpp.bin"
  "$native" compile --src-prefix "$inputs" -o "$work/ir local out" \
    --request-output "$work/ir-evolution-$version-native.bin" \
    "$inputs/evolution-$version.capnp"
  "$native" normalize-request "$work/ir-evolution-$version-cpp.bin" \
    > "$work/ir-evolution-$version-cpp.txt"
  "$native" normalize-request "$work/ir-evolution-$version-native.bin" \
    > "$work/ir-evolution-$version-native.txt"
  diff -u "$work/ir-evolution-$version-cpp.txt" "$work/ir-evolution-$version-native.txt"
done
swift format --in-place --configuration "$root/.swift-format" "$first/test.capnp.swift"
swift format --in-place --configuration "$root/.swift-format" "$first/advanced.capnp.swift"
swift format --in-place --configuration "$root/.swift-format" "$first/interfaces.capnp.swift"
diff -u "$root/Tests/Generated/CapnpTest/test.capnp.swift" "$first/test.capnp.swift"
diff -u "$root/Tests/Generated/CompilerFixtures/advanced.capnp.swift" \
  "$first/advanced.capnp.swift"
diff -u "$root/Tests/Generated/CompilerFixtures/interfaces.capnp.swift" \
  "$first/interfaces.capnp.swift"

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
            dependencies: [
                .product(name: "CapnProto", package: "swift-capnproto"),
                .product(name: "CapnProtoRPC", package: "swift-capnproto")
            ])
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
"${swiftc[@]}" -typecheck -swift-version 6 -I "$root/.build/debug/Modules" \
  "$upstream_first/test.capnp.swift"
native_test="$work/native test"
mkdir -p "$native_test"
"$capnp" compile --no-standard-import -I"$upstream_import_root" -o- \
  --src-prefix="$upstream" "$upstream/test.capnp" > "$work/ir-test-cpp.bin"
"$native" compile -I"$upstream_import_root" --src-prefix "$upstream" \
  -o "$native_test" --request-output "$work/ir-test-native.bin" "$upstream/test.capnp"
"${swiftc[@]}" -typecheck -swift-version 6 -I "$root/.build/debug/Modules" \
  "$native_test/test.capnp.swift"
"$native" normalize-request "$work/ir-test-cpp.bin" > "$work/ir-test-cpp.txt"
"$native" normalize-request "$work/ir-test-native.bin" > "$work/ir-test-native.txt"
diff -u "$work/ir-test-cpp.txt" "$work/ir-test-native.txt"

native_imports="$work/native imports"
mkdir -p "$native_imports"
"$capnp" compile --no-standard-import -I"$upstream_import_root" -o- \
  --src-prefix="$upstream" "$upstream/test-import2.capnp" > "$work/ir-imports-cpp.bin"
"$native" compile -I"$upstream_import_root" --src-prefix "$upstream" \
  -o "$native_imports" --request-output "$work/ir-imports-native.bin" \
  "$upstream/test-import2.capnp"
"$native" normalize-request "$work/ir-imports-cpp.bin" > "$work/ir-imports-cpp.txt"
"$native" normalize-request "$work/ir-imports-native.bin" > "$work/ir-imports-native.txt"
diff -u "$work/ir-imports-cpp.txt" "$work/ir-imports-native.txt"

interfaces_first="$work/interfaces first"
interfaces_second="$work/interfaces second"
mkdir -p "$interfaces_first" "$interfaces_second"
"$capnp" compile --no-standard-import -I"$upstream_import_root" \
  -o"$tool:$interfaces_first" --src-prefix="$upstream" \
  "$upstream/rpc.capnp" "$upstream/rpc-twoparty.capnp"
"$capnp" compile --no-standard-import -I"$upstream_import_root" \
  -o"$tool:$interfaces_second" --src-prefix="$upstream" \
  "$upstream/rpc.capnp" "$upstream/rpc-twoparty.capnp"
diff -ru "$interfaces_first" "$interfaces_second"
native_interfaces="$work/native interfaces"
mkdir -p "$native_interfaces"
"$native" compile -I"$upstream_import_root" --src-prefix "$upstream" \
  -o "$native_interfaces" "$upstream/rpc.capnp" "$upstream/rpc-twoparty.capnp"
diff -u "$interfaces_first/rpc.capnp.swift" "$native_interfaces/rpc.capnp.swift"
diff -u "$interfaces_first/rpc-twoparty.capnp.swift" \
  "$native_interfaces/rpc-twoparty.capnp.swift"
"$capnp" compile --no-standard-import -I"$upstream_import_root" -o- \
  --src-prefix="$upstream" "$upstream/rpc.capnp" "$upstream/rpc-twoparty.capnp" \
  > "$work/ir-rpc-cpp.bin"
"$native" compile -I"$upstream_import_root" --src-prefix "$upstream" \
  -o "$native_interfaces" --request-output "$work/ir-rpc-native.bin" \
  "$upstream/rpc.capnp" "$upstream/rpc-twoparty.capnp"
"$native" normalize-request "$work/ir-rpc-cpp.bin" > "$work/ir-rpc-cpp.txt"
"$native" normalize-request "$work/ir-rpc-native.bin" > "$work/ir-rpc-native.txt"
diff -u "$work/ir-rpc-cpp.txt" "$work/ir-rpc-native.txt"
"${swiftc[@]}" -typecheck -swift-version 6 -I "$root/.build/debug/Modules" \
  "$interfaces_first/rpc.capnp.swift" "$interfaces_first/rpc-twoparty.capnp.swift"

echo "local, imports, evolution, test, RPC, and two-party IR/codegen verification passed"
