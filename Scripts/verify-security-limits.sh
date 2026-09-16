#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/Tests/Security/LIMITS.tsv"
count=0
while IFS=$'\t' read -r boundary implementation regression; do
  [[ -z "$boundary" || "$boundary" == \#* ]] && continue
  [[ -f "$root/$implementation" ]] || { echo "missing limit implementation: $implementation" >&2; exit 1; }
  rg -q "func $regression\\b" "$root/Tests" || {
    echo "missing boundary regression for $boundary: $regression" >&2
    exit 1
  }
  count=$((count + 1))
done < "$manifest"
[[ "$count" -ge 12 ]]
echo "$count published hostile-input boundaries have regression coverage"
