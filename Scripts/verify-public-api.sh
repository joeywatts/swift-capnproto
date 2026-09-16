#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift package dump-symbol-graph --minimum-access-level public >/dev/null
symbol_dir="$(find "$root/.build" -type d -name symbolgraph -print -quit)"
[[ -n "$symbol_dir" ]]
for name in BuilderArena BuilderSegment ReaderState ResolvedPointer ByteMailbox PendingWireQuestion NativeTranslator; do
  if grep -ERn "^public (final )?(class|struct|enum|actor|protocol) ${name}([^[:alnum:]_]|$)" "$root/Sources"; then
    echo "internal wire implementation leaked into public API: $name" >&2
    exit 1
  fi
  if grep -FRq "\"title\":\"$name\"" "$symbol_dir"; then
    echo "internal wire implementation appears in public symbol graph: $name" >&2
    exit 1
  fi
done
echo "public API contains no reviewed internal wire implementation types"
