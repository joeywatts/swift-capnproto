#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# shellcheck disable=SC1091
source Tests/Upstream/BASELINES

[[ "$CAPNPROTO_REV" =~ ^[0-9a-f]{40}$ ]]
[[ "$CAPNP_TEST_REV" =~ ^[0-9a-f]{40}$ ]]
[[ "$CAPNP_TEST_REV" == 9aad1331857d2b02158cffdba4d664f71f7f81de ]]
grep -Fq "CAPNP_TEST_UPSTREAM_REV = \"$CAPNP_TEST_REV\"" flake.nix
grep -Fq "$CAPNPROTO_REV" Documentation/Compatibility.md
grep -Fq "$CAPNPROTO_REV" THIRD_PARTY_NOTICES.md

shasum -a 256 -c Tests/Upstream/capnproto.sha256

while IFS=$'\t' read -r feature sources; do
  [[ -z "$feature" || "$feature" == \#* ]] && continue
  [[ -n "$sources" ]] || {
    echo "release-blocking feature has no upstream source: $feature" >&2
    exit 1
  }
  IFS=',' read -ra paths <<< "$sources"
  for path in "${paths[@]}"; do
    [[ -f "Tests/Upstream/capnproto/$path" ]] || {
      echo "traceability source is not imported: $path" >&2
      exit 1
    }
    grep -Fq "  Tests/Upstream/capnproto/$path" Tests/Upstream/capnproto.sha256 || {
      echo "traceability source is not checksummed: $path" >&2
      exit 1
    }
  done
done < Tests/Upstream/FEATURES.tsv

echo "upstream provenance and feature traceability verified"
