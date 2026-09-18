#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$root/.build/apple-platforms"

# Building CapnProtoNIO exercises the full runtime-library dependency graph:
# CapnProto, CapnProtoSchema, CapnProtoRPC, and the optional NIO transport.
platforms=(
  "iphonesimulator arm64-apple-ios17.0-simulator"
  "appletvsimulator arm64-apple-tvos17.0-simulator"
  "watchsimulator arm64-apple-watchos10.0-simulator"
  "xrsimulator arm64-apple-xros1.0-simulator"
)

for platform in "${platforms[@]}"; do
  read -r sdk triple <<< "$platform"
  swift build \
    --package-path "$root" \
    --scratch-path "$scratch" \
    --triple "$triple" \
    --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    --target CapnProtoNIO
done
