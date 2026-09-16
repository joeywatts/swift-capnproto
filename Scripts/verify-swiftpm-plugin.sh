#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
example="$work/plugin example with spaces"
mkdir -p "$example"
cp "$root/Examples/PluginExample/Package.swift" "$example"
cp -R "$root/Examples/PluginExample/Sources" "$example/Sources"

build_example() {
  local report="$1"
  local clean_path=""
  local directory
  while IFS= read -r directory; do
    if [[ ! -x "$directory/capnp" ]]; then
      clean_path="${clean_path:+$clean_path:}$directory"
    fi
  done < <(tr ':' '\n' <<< "$PATH")
  if ! PATH="$clean_path" SWIFT_CAPNPROTO_PATH="$root" \
    swift build --package-path "$example" >"$report" 2>&1
  then
    cat "$report" >&2
    return 1
  fi
}

build_example "$work/clean.log"
[[ "$(grep -c 'Generating .*capnp' "$work/clean.log" || true)" == 2 ]] || {
  cat "$work/clean.log" >&2
  echo "clean build did not generate exactly two schemas" >&2
  exit 1
}

build_example "$work/incremental.log"
if grep -q 'Generating .*capnp' "$work/incremental.log"; then
  cat "$work/incremental.log" >&2
  echo "no-change build unexpectedly regenerated schemas" >&2
  exit 1
fi

touch "$example/README.md"
build_example "$work/unrelated.log"
if grep -q 'Generating .*capnp' "$work/unrelated.log"; then
  cat "$work/unrelated.log" >&2
  echo "unrelated file change unexpectedly regenerated schemas" >&2
  exit 1
fi

touch "$example/Sources/PluginExample/Schemas/common.capnp"
build_example "$work/import.log"
[[ "$(grep -c 'Generating .*capnp' "$work/import.log" || true)" == 2 ]] || {
  cat "$work/import.log" >&2
  echo "import change did not regenerate dependent schema outputs" >&2
  exit 1
}

output="$("$example/.build/debug/PluginExample")"
[[ "$output" == "hello from generated Swift #3" ]] || {
  echo "unexpected example output: $output" >&2
  exit 1
}

echo "SwiftPM plugin clean, incremental, import, module, path-space, and capnp-free checks passed"
