#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
Scripts/verify-examples.sh

for document in Compatibility GeneratedAPI Migration Performance PublicAPI \
  RPCConformance RPCTutorial Security SupportedPlatforms Versioning; do
  [[ -s "Documentation/$document.md" ]] || { echo "missing documentation: $document" >&2; exit 1; }
done

if command -v xcrun >/dev/null 2>&1; then
  swift package dump-symbol-graph --minimum-access-level public >/dev/null
  symbol_dir="$(find .build -type d -name symbolgraph -print -quit)"
  output="$(mktemp -d)"
  trap 'rm -rf "$output"' EXIT
  xcrun docc convert Sources/CapnProto/CapnProto.docc \
    --additional-symbol-graph-dir "$symbol_dir" \
    --output-path "$output/archive" \
    --fallback-display-name CapnProto \
    --fallback-bundle-identifier org.swift-capnproto.CapnProto \
    --fallback-bundle-version "$(tr -d '\n' < VERSION)" \
    --warnings-as-errors
fi

echo "documentation catalog validates and every executable snippet compiles and runs"
