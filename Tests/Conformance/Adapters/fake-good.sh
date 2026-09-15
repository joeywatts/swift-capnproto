#!/usr/bin/env bash
set -euo pipefail

operation="$1"
test_name="$2"
schema="$(cd "$(dirname "$0")/../capnp_test" && pwd)/test.capnp"

case "$operation" in
  decode) capnp eval --short "$schema" "$test_name" ;;
  encode) capnp eval --binary "$schema" "$test_name" ;;
  *) exit 64 ;;
esac
