#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '\n' < "$root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

(cd "$root" && shasum -a 256 -c "Release/$version-CHECKSUMS")
"$root/Scripts/verify-fixtures.sh"
"$root/Scripts/verify-schema-bootstrap.sh"
"$root/Scripts/verify-swift-codegen.sh"
"$root/Scripts/verify-public-api.sh"
for implementation in swift capnproto-c++ capnproto-rust; do
  [[ "$(grep -c "\"implementation\":\"$implementation\"" "$root/Benchmarks/comparison.jsonl")" -ge 20 ]]
done
swift build --package-path "$root/Tests/Consumer" -c release

first="$(mktemp)"
second="$(mktemp)"
trap 'rm -f "$first" "$second"' EXIT
(cd "$root" && git archive --format=tar --prefix="swift-capnproto-$version/" HEAD | gzip -n > "$first")
(cd "$root" && git archive --format=tar --prefix="swift-capnproto-$version/" HEAD | gzip -n > "$second")
cmp "$first" "$second"
echo "release inputs, generated sources, clean consumer, and source archives are reproducible"
