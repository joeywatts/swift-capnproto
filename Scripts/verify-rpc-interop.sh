#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
work="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]-}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

swift build --package-path "$root" --product capnp-rpc-interop-swift
swift_tool="$root/.build/debug/capnp-rpc-interop-swift"
schema="$root/Tests/InteropFixtures/rpc-interop.capnp"
"$prefix/bin/capnp" compile -o"$prefix/bin/capnpc-c++:$work" \
  --src-prefix="$(dirname "$schema")" "$schema"
c++ -std=c++20 -O2 -pthread -I"$prefix/include" -I"$work" \
  "$root/Tools/RPCInterop/rpc-interop.c++" "$work/rpc-interop.capnp.c++" \
  -L"$prefix/lib" -lcapnp-rpc -lcapnp -lkj-async -lkj -o "$work/cpp-rpc"

run_pair() {
  local server="$1"
  local client="$2"
  local tag="$3"
  local port_file="$work/$tag.port"
  local output_file="$work/$tag.output"
  echo "running $tag"
  "$server" server >"$port_file" &
  local server_pid=$!
  pids+=("$server_pid")
  for _ in $(seq 1 100); do
    [[ -s "$port_file" ]] && break
    sleep 0.02
  done
  [[ -s "$port_file" ]]
  local port
  port="$(head -1 "$port_file")"
  "$client" client "$port" >"$output_file"
  wait "$server_pid"
  [[ "$(tail -1 "$output_file")" == "42" ]]
}

run_pair "$swift_tool" "$swift_tool" swift-to-swift
run_pair "$work/cpp-rpc" "$swift_tool" swift-to-cpp
run_pair "$swift_tool" "$work/cpp-rpc" cpp-to-swift
run_pair "$work/cpp-rpc" "$work/cpp-rpc" cpp-to-cpp

echo "RPC live matrix passed: Swift/Swift, Swift/C++, C++/Swift, C++/C++"
