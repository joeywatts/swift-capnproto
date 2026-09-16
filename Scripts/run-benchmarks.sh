#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$(cd "$root" && swift run -c release capnp-benchmark)"
[[ "$(printf '%s\n' "$output" | grep -cE '^\{"implementation":"swift"')" == 5 ]]
printf '%s\n' "$output"

while IFS=$'\t' read -r name baseline factor; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  line="$(printf '%s\n' "$output" | grep -F "\"benchmark\":\"$name\"")"
  iterations="$(sed -E 's/.*"iterations":([0-9]+).*/\1/' <<< "$line")"
  elapsed="$(sed -E 's/.*"nanoseconds":([0-9]+).*/\1/' <<< "$line")"
  per_iteration=$((elapsed / iterations))
  maximum=$((baseline * factor))
  if (( per_iteration > maximum )); then
    echo "$name regressed to ${per_iteration}ns/iteration; major-regression limit is ${maximum}ns" >&2
    exit 1
  fi
done < "$root/Benchmarks/BASELINES.tsv"

echo "benchmark results remain below stored major-regression thresholds"
