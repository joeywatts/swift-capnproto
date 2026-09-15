#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift package describe --type json > "${TMPDIR:-/tmp}/swift-capnproto-package.json"

if rg -n --glob '*.swift' '(import (CapnProtoC|CCapnProto)\b|-l(capnp|kj)\b)' Sources Package.swift; then
  echo "a shipped target references a Cap'n Proto C/C++ library" >&2
  exit 1
fi

swift build

for binary in capnpc-swift capnp-swift capnp-test-swift; do
  path="$(swift build --show-bin-path)/$binary"
  if [[ "$(uname -s)" == Darwin ]]; then
    if otool -L "$path" | rg -i '(libcapnp|libkj)'; then
      echo "$binary links a Cap'n Proto C/C++ library" >&2
      exit 1
    fi
  elif ldd "$path" | rg -i '(libcapnp|libkj)'; then
    echo "$binary links a Cap'n Proto C/C++ library" >&2
    exit 1
  fi
done
