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
  --src-prefix="$schema" "$schema/advanced.capnp"
swift format --in-place "$output/advanced.capnp.swift"

echo "regenerated $output/advanced.capnp.swift"
