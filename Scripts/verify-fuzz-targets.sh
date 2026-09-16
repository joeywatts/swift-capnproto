#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
corpus=("$root"/Tests/InteropFixtures/generated/*.bin)
[[ "${#corpus[@]}" == 8 ]]
malformed=("$root"/Fuzz/Seeds/*.bin)
mutations=("$root"/Fuzz/Mutation/*.bin)
swift run capnp-fuzz-message "${corpus[@]}" "${malformed[@]}" "${mutations[@]}"
swift run capnp-fuzz-packed "${corpus[@]}" "${malformed[@]}" "${mutations[@]}"
swift run capnp-fuzz-schema "${corpus[@]}" "${malformed[@]}" "${mutations[@]}"
echo "all fuzz targets safely consumed the upstream-derived and malformed corpus seeds"
