#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
driver="$("$root/Scripts/build-fixture-oracle.sh")"
output_dir="${1:-$root/Tests/InteropFixtures/generated}"
mkdir -p "$output_dir"

for fixture in flat stream packed multi-segment defaults union group nested-list; do
  "$driver" generate "$fixture" "$output_dir/$fixture.bin"
done
