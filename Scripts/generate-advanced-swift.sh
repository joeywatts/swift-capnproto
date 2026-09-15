#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
schema="$root/Tests/CapnProtoCompilerTests/Fixtures"
output="$root/Tests/Generated/CompilerFixtures"

cd "$root"
swift build --product capnpc-swift
"$prefix/bin/capnp" compile \
  -o"$root/.build/debug/capnpc-swift:$output" \
  --src-prefix="$schema" "$schema/advanced.capnp" "$schema/interfaces.capnp"
swift format --in-place "$output/advanced.capnp.swift" "$output/interfaces.capnp.swift"

echo "regenerated compiler fixture Swift in $output"
