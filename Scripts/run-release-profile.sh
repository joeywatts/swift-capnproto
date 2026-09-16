#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

Scripts/prepare-reference-capnp.sh >/dev/null
Scripts/verify-swift-tests.sh
Scripts/check-package-boundaries.sh
Scripts/verify-upstream.sh
Scripts/verify-capnp-test.sh
Scripts/verify-fixtures.sh
Scripts/verify-fuzz-targets.sh
Scripts/verify-security-limits.sh
Scripts/verify-examples.sh
Scripts/verify-documentation.sh
Scripts/verify-generated-interop.sh
Scripts/verify-rpc-interop.sh
RPC_SOAK_SECONDS="${RPC_SOAK_SECONDS:-60}" Scripts/run-rpc-soak.sh
Scripts/run-benchmarks.sh
Scripts/verify-release-reproducibility.sh

echo "full 1.0 release profile passed without skips"
