# Published 1.0 benchmark comparison

`comparison.jsonl` was recorded on Apple Silicon (`arm64`, macOS 26.0) with
Apple Swift 6.3.3, Apple Clang 21.0.0, Cap'n Proto C++ 1.4.0, capnproto-rust
0.27.2, and rustc 1.98.1. Each row is one optimized run of 10,000 iterations;
rerun `Scripts/run-comparative-benchmarks.sh` five times for release medians.

All implementations use `benchmark.capnp`: one `UInt64` and a 256-byte `Data`
field. The Swift benchmark uses the equivalent checked untyped layout. Raw
nanoseconds and checksums are retained rather than presenting cross-machine
ratios as universal performance claims.
