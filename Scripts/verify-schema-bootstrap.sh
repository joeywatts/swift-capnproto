#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/Tests/Upstream/BASELINES"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
capnp="$prefix/bin/capnp"
schema="$prefix/include/capnp/schema.capnp"
upstream="$root/.build/reference-capnp/$CAPNPROTO_REV/source/c++/src"
tool="$root/.build/debug/capnpc-swift"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$root"
swift build --product capnpc-swift

verify_request() {
  local name="$1"
  shift
  "$capnp" compile -o- -I"$upstream" "$@" > "$work/$name.request"
  "$tool" --bootstrap-inspect < "$work/$name.request" >&2
  "$tool" --bootstrap-roundtrip < "$work/$name.request" > "$work/$name.copy"
  "$capnp" decode "$schema" CodeGeneratorRequest < "$work/$name.request" > "$work/$name.txt"
  "$capnp" decode "$schema" CodeGeneratorRequest < "$work/$name.copy" > "$work/$name.copy.txt"
  diff -u "$work/$name.txt" "$work/$name.copy.txt"
}

verify_request test "$upstream/capnp/test.capnp"
verify_request imports "$upstream/capnp/test-import.capnp" "$upstream/capnp/test-import2.capnp"
verify_request rpc "$upstream/capnp/rpc.capnp"
verify_request rpc-twoparty "$upstream/capnp/rpc-twoparty.capnp"

echo "schema bootstrap requests round-trip semantically"
