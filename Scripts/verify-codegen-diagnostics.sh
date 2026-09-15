#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
capnp="$prefix/bin/capnp"
tool="$root/.build/debug/capnpc-swift"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$root"
swift build --product capnpc-swift

mkdir -p "$work/malformed output"
if printf 'not a code generator request' | (cd "$work/malformed output" && "$tool") \
  >"$work/malformed.stdout" 2>"$work/malformed.stderr"
then
  echo "malformed request unexpectedly succeeded" >&2
  exit 1
fi
grep -q '^capnpc-swift:' "$work/malformed.stderr"
if find "$work/malformed output" -name '*.swift' -print -quit | grep -q .; then
  echo "malformed request produced partial Swift output" >&2
  exit 1
fi

mkdir -p "$work/source errors"
if "$capnp" compile -o"$tool:$work/source errors" \
  "$root/Tests/CapnProtoCompilerTests/Fixtures/malformed.capnp" \
  >"$work/source.stdout" 2>"$work/source.stderr"
then
  echo "malformed schema unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'malformed.capnp:.*error:' "$work/source.stderr"
if find "$work/source errors" -name '*.swift' -print -quit | grep -q .; then
  echo "source error produced partial Swift output" >&2
  exit 1
fi

echo "codegen errors are source-located and malformed requests leave no partial output"
