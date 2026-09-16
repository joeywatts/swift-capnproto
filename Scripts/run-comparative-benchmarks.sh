#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
iterations="${CAPNP_BENCHMARK_ITERATIONS:-10000}"
runs="${CAPNP_BENCHMARK_RUNS:-5}"
output="${CAPNP_BENCHMARK_OUTPUT:-$root/Benchmarks/comparison.jsonl}"
cpp="${TMPDIR:-/tmp}/swift-capnproto-cpp-benchmark"
generated="$(mktemp -d)"
trap 'rm -rf "$generated"' EXIT

capnp compile -oc++:"$generated" --src-prefix="$root/Tools/Benchmarks" \
  "$root/Tools/Benchmarks/benchmark.capnp"
c++ -O3 -std=c++20 $(pkg-config --cflags capnp) \
  -I"$generated" "$root/Tools/Benchmarks/cpp-benchmark.c++" \
  "$generated/benchmark.capnp.c++" $(pkg-config --libs capnp) -o "$cpp"
cargo build --release --locked --manifest-path "$root/Tools/Benchmarks/Rust/Cargo.toml"

for _ in $(seq 1 "$runs"); do
  {
    CAPNP_BENCHMARK_ITERATIONS="$iterations" swift run -c release \
      --package-path "$root" capnp-benchmark
    "$cpp" "$iterations"
    "$root/Tools/Benchmarks/Rust/target/release/capnp-rust-benchmark" "$iterations"
  }
done | grep -E '^\{' > "$output"

for implementation in swift capnproto-c++ capnproto-rust; do
  count="$(grep -c "\"implementation\":\"$implementation\"" "$output" || true)"
  [[ "$count" -ge $((runs * 4)) ]] || {
    echo "missing comparison rows for $implementation" >&2
    exit 1
  }
done
echo "wrote reproducible Swift, C++, and Rust comparison to $output"
