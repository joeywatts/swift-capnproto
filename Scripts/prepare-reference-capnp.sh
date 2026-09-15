#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/Tests/Upstream/BASELINES"

base="$root/.build/reference-capnp/$CAPNPROTO_REV"
source_dir="$base/source"
build_dir="$base/build"
prefix="$base/install"

if [[ ! -x "$prefix/bin/capnp" ]]; then
  if [[ ! -d "$source_dir/.git" ]]; then
    mkdir -p "$base"
    git clone --quiet https://github.com/capnproto/capnproto.git "$source_dir"
  fi
  git -C "$source_dir" checkout --quiet "$CAPNPROTO_REV"
  [[ "$(git -C "$source_dir" rev-parse HEAD)" == "$CAPNPROTO_REV" ]]
  cmake -S "$source_dir" -B "$build_dir" \
    -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" >&2
  cmake --build "$build_dir" --parallel >&2
  cmake --install "$build_dir" >&2
  printf '%s\n' "$CAPNPROTO_REV" > "$prefix/.capnproto-revision"
fi

[[ "$(<"$prefix/.capnproto-revision")" == "$CAPNPROTO_REV" ]]
printf '%s\n' "$prefix"
