#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/Tests/Upstream/BASELINES"
driver="$("$root/Scripts/build-fixture-oracle.sh")"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

CAPNP_REFERENCE_PREFIX="${CAPNP_REFERENCE_PREFIX:-$("$root/Scripts/prepare-reference-capnp.sh")}" \
  "$root/Scripts/generate-fixtures.sh" "$temporary"

jq -e --arg revision "$CAPNPROTO_REV" '
  .upstreamCommit == $revision and
  .schema == "Tests/InteropFixtures/fixture.capnp" and
  (.fixtures | length == 8) and
  all(.fixtures[];
    .upstreamCommit == $revision and
    (.sourceTests | length > 0) and
    (.producingCommand | length > 0) and
    (.encoding == "flat" or .encoding == "stream" or .encoding == "packed")
  )
' "$root/Tests/InteropFixtures/manifest.json" >/dev/null

while IFS= read -r source_test; do
  [[ -f "$root/Tests/Upstream/capnproto/$source_test" ]]
done < <(jq -r '.fixtures[].sourceTests[]' "$root/Tests/InteropFixtures/manifest.json" | sort -u)

for fixture in flat stream packed multi-segment defaults union group nested-list; do
  cmp "$temporary/$fixture.bin" "$root/Tests/InteropFixtures/generated/$fixture.bin"
  actual="$($driver decode "$fixture" "$temporary/$fixture.bin" | jq -cS .)"
  expected="$(jq -cS --arg fixture "$fixture" \
    '.fixtures[] | select(.name == $fixture) | .expectedSemantic' \
    "$root/Tests/InteropFixtures/manifest.json")"
  [[ "$actual" == "$expected" ]] || {
    echo "$fixture semantic mismatch" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  }
done

echo "golden fixtures regenerate byte-for-byte and decode to expected values"
