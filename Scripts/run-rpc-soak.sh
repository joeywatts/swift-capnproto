#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
duration="${RPC_SOAK_SECONDS:-86400}"
half=$((duration / 2))
((half > 0)) || half=1

swift run --package-path "$root" --sanitize=address capnp-rpc-soak --seconds "$half"
swift run --package-path "$root" --sanitize=thread capnp-rpc-soak --seconds "$half"

echo "RPC ASan/TSan soak completed for ${duration}s total"
