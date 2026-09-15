# RPC conformance ledger

Baseline: capnproto/capnproto `3a82de9b39736a2625f03c93b2b7c50642dd5b25`.

| Upstream area | Swift evidence | Classification |
| --- | --- | --- |
| `capability-test.c++` local calls, inheritance, exceptions, promises | `CapabilityTests.swift` | Ported |
| `rpc-test.c++` bootstrap, basic calls, returns, finish/release | `TwoPartyConnectionTests.swift` | Ported |
| `rpc-test.c++` promised answers, ordering, resolve loops | `CapabilityTests.swift`, `TwoPartyConnectionTests.swift` | Ported |
| `rpc-test.c++` embargo/disembargo | `TwoPartyConnectionTests.swift`, `RPCWireValidationTests.swift` | Ported |
| `rpc-test.c++` cancellation, tail returns, streaming | `TwoPartyConnectionTests.swift`, `RPCConformanceTests.swift` | Ported |
| `rpc-twoparty-test.c++` TCP bootstrap and calls | `CapnProtoNIOTests`, `verify-rpc-interop.sh` | Differential/live |
| `ez-rpc-test.c++` client/server setup | `verify-rpc-interop.sh` | Differential/live |
| Three-party `provide`, `accept`, and `join` | Outside two-party Milestone 6 scope; rejected before mutation | Not applicable |

`Scripts/verify-rpc-interop.sh` runs the required Swift/Swift, Swift/C++,
C++/Swift, and C++/C++ control matrix against the pinned upstream build.
`Scripts/run-rpc-soak.sh` defaults to a combined 24-hour ASan/TSan churn run;
`RPC_SOAK_SECONDS` selects a shorter presubmit smoke run.
