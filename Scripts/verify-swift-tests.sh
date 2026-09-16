#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
suites=(
  CapnProtoTests
  CapnProtoSchemaTests
  CapnProtoCompilerTests
  CapnProtoTestSupportTests
  CapnProtoNIOTests
  CapnProtoRPCTests
)
for suite in "${suites[@]}"; do
  swift test --disable-xctest --enable-swift-testing "$@" --filter "$suite"
done
echo "all Swift test targets passed"
