# RPC conformance ledger

Baseline: capnproto/capnproto `3a82de9b39736a2625f03c93b2b7c50642dd5b25`.
The rows map release-blocking behavior rather than merely naming an upstream
file. “Covered” means the Swift test executes the same wire transition or
invariant. Waivers are limited to APIs outside Milestone 6.

| Upstream cases | Swift evidence | Status |
| --- | --- | --- |
| `Capability.Basic`, capability lists, inheritance | Local capability and generated-interface tests | Covered |
| Pipelining, use after response drop, `context.setPipeline`, remote-promise flattening | Local and promised-answer pipeline ordering tests | Covered |
| `Capability.TailCall`, `AsyncCancelation` | Standard tail handoff and reverse-callee cancellation tests | Covered on the wire |
| Dynamic client/server, inheritance, pipelining, any-cap, lists, keywords, generics | Dynamic and generated API suites | Covered |
| `clone() with caps`, transfer-cap | Graph-copy capability tests and parameter/result cap passing | Covered |
| Streaming block, cancel, and error cascade | Streaming flow-control, cancellation, and failure-cascade tests | Covered |
| `Rpc.Basic`, `Pipelining`, `sendForPipeline`, `context.setPipeline` | Bootstrap/basic and promised-answer transform tests | Covered |
| `Rpc.Release`, `ReleaseOnCancel`, `RetainAndRelease` | Table, duplicate-export, cancellation, and table-zero assertions | Covered |
| `Rpc.TailCall`, `TailCallCancel`, `TailCallCancelRace` | `yourself` / `takeFromOtherQuestion` / `resultsSentElsewhere` handshake | Covered |
| `Rpc.Cancellation`, `Cancel` | Wire cancellation and disconnect-at-transition tests | Covered |
| `Rpc.PromiseResolve`, `CallBrokenPromise`, export same promise twice | Capability/error/redirect and duplicate-export regressions | Covered |
| `Rpc.SendTwice`; outgoing send failure cleanup | Serialized writes and failed-send export rollback | Covered |
| `Rpc.Embargo`, error/null embargo, two-party loopback | Standards-correct loopback test; conservative promise forwarding | Covered |
| `Rpc.Abort`, invalid exception, disconnect and method exceptions | Transactional validator, exception, and injected-fault tests | Covered |
| Two-party basic, pipeline, release, abort, setup, bootstrap factory | NIO tests and four-way live matrix | Covered / differential |
| Huge message and write/read error propagation | Message-limit and transport-fault tests | Covered |
| Two-party streaming, promise-send race, dropped-capability lifetime | Streaming, promise, cancellation, and accounting tests | Covered |
| TCP/Unix framing, write ordering, backpressure, half-close, shutdown | NIO tests and live matrix | Covered |
| `EzRpc.Basic` | Four-way live matrix setup | Covered / differential |
| FD attachment and per-message FD limits | Ancillary FD passing is not listed in Milestone 6.6 and has no Swift API | Waived: not release-blocking |
| `CapabilityServerSet`, unwrap, `ThisCap`, `RevocableServer` | Local convenience/lifecycle APIs, not RPC wire features | Waived: outside Milestone 6 |
| C++ trace encoder and deprecated EZ-RPC names | C++-specific diagnostics/source compatibility | Waived: not applicable |
| Three-party `provide`, `accept`, `join`, and embargo | Rejected transactionally by the two-party runtime | Waived: outside two-party Milestone 6 |

`Scripts/verify-rpc-interop.sh` runs Swift→Swift, Swift→C++, C++→Swift,
and C++→C++ against the pinned upstream build. The live schema includes a
non-empty promised-answer transform and a call through the returned capability.

`Scripts/run-rpc-soak.sh` defaults to a combined 24-hour run: 12 hours under
AddressSanitizer followed by 12 hours under ThreadSanitizer. Each iteration
reconnects, churns capabilities, checks results, and asserts every live table is
empty after shutdown. `RPC_SOAK_SECONDS` selects a shorter presubmit smoke run.
