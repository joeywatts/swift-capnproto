#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="${CAPNP_REFERENCE_PREFIX:-$("$root/Scripts/prepare-reference-capnp.sh")}"
# shellcheck disable=SC1091
source "$root/Tests/Upstream/BASELINES"
[[ "$(<"$prefix/.capnproto-revision")" == "$CAPNPROTO_REV" ]]

build="$root/.build/fixture-oracle"
generated="$build/generated"
mkdir -p "$generated"
PATH="$prefix/bin:$PATH" "$prefix/bin/capnp" compile \
  --src-prefix="$root/Tests/InteropFixtures" -oc++:"$generated" \
  "$root/Tests/InteropFixtures/fixture.capnp"

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
read -r -a capnp_flags <<< "$(pkg-config --cflags --libs capnp)"
${CXX:-c++} -std=c++20 -O2 -I"$generated" \
  "$root/Tools/FixtureOracle/fixture-driver.c++" \
  "$generated/fixture.capnp.c++" \
  "${capnp_flags[@]}" -o "$build/fixture-driver"

printf '%s\n' "$build/fixture-driver"
