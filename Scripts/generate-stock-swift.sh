#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
schema="$root/Tests/Conformance/capnp_test"
output="$root/Tests/Generated/CapnpTest"

cd "$root"
swift build --product capnpc-swift
"$prefix/bin/capnp" compile \
  -o"$root/.build/debug/capnpc-swift:$output" \
  --src-prefix="$schema" "$schema/test.capnp"
swift format --in-place "$output/test.capnp.swift"

echo "regenerated $output/test.capnp.swift"
