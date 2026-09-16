#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build --product capnp-example-address-book
swift build --product capnp-example-evolution
swift build --product capnp-example-calculator
swift build --product capnp-example-pipeline

[[ "$(swift run --skip-build capnp-example-address-book)" == "42: Ada" ]]
[[ "$(swift run --skip-build capnp-example-evolution)" == "original=7 added=99" ]]
[[ "$(swift run --skip-build capnp-example-calculator)" == "42" ]]
[[ "$(swift run --skip-build capnp-example-pipeline)" == "42" ]]

if command -v capnp >/dev/null 2>&1; then
  output="$(mktemp)"
  trap 'rm -f "$output"' EXIT
  swift run --skip-build capnp-example-address-book --write "$output" >/dev/null
  decoded="$(capnp decode Examples/AddressBook/addressbook.capnp Person < "$output")"
  grep -Fq 'id = 42' <<< "$decoded"
  grep -Fq 'name = "Ada"' <<< "$decoded"
fi

echo "documentation examples compile, run, and serialize C++-compatible address data"
