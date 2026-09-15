#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$(cd "$root" && swift run -c release capnp-benchmark)"
[[ "$(printf '%s\n' "$output" | grep -cE '^\{"benchmark"')" == 5 ]]
printf '%s\n' "$output"
