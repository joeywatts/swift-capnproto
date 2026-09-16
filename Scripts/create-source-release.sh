#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '\n' < "$root/VERSION")"
output="${1:-$root/.build/release}"
archive="swift-capnproto-$version.tar.gz"
mkdir -p "$output"
(cd "$root" && git archive --format=tar --prefix="swift-capnproto-$version/" HEAD) \
  | gzip -n > "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > SHA256SUMS)
echo "$output/$archive"
