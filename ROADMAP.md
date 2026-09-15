# Swift Cap'n Proto implementation roadmap

## Goal and scope

Build a production-quality Cap'n Proto implementation whose runtime, generated
code, compiler, and RPC stack are written in Swift. No shipped target links the
upstream C++ implementation. The upstream `capnp` tool may be used in development
and CI as a pinned interoperability oracle.

The compatibility baseline is the Cap'n Proto 1.x `master` branch. Milestone
0 pins one exact upstream commit and records any intentionally unsupported
features. Work on the incompatible upstream v2 development branch is deferred
until after the first stable release.

“Complete” means:

- standard and packed serialization, multi-segment messages, canonicalization,
  schema evolution, limits, and safe handling of untrusted input;
- generated, strongly typed Swift readers, builders, enums, groups, unions,
  constants, generics, and capability interfaces;
- dynamic schema/reflection support;
- Level 3 capability RPC, including promise pipelining, capability passing,
  cancellation, embargo/disembargo, and the two-party network protocol;
- both a `capnpc-swift` plugin and a self-contained Swift schema compiler/build
  plugin; and
- macOS and Linux support in Swift 6 language mode with strict concurrency.

JSON/text codecs, persistent capabilities, membranes, WebSocket RPC, and v2
protocol support are useful follow-on features, but are not release blockers
unless promoted before Milestone 0 closes.

## Package architecture

| Product/target | Responsibility |
| --- | --- |
| `CapnProto` | Words, segments, arenas, checked layout, readers/builders, standard and packed framing |
| `CapnProtoSchema` | Bootstrapped `schema.capnp` types, reflection, dynamic values, schema registry |
| `CapnProtoRPC` | Capability API, RPC state machine, protocol messages, transport abstraction |
| `CapnProtoNIO` | Optional SwiftNIO byte-stream transport for production TCP/Unix sockets |
| `CapnProtoCompiler` | Lexer, parser, resolver, layout/type checker, and Swift emitter |
| `capnpc-swift` | Standard compiler plugin: binary `CodeGeneratorRequest` on stdin, generated files on disk |
| `capnp-swift` | Self-contained schema compiler and developer CLI |
| `CapnProtoPlugin` | SwiftPM build-tool plugin for `.capnp` inputs |
| `capnp-test-swift` | Development-only adapter implementing the `kaos/capnp_test` encode/decode contract |

The core target should have no networking or compiler dependency. Readers own or
share immutable message storage so a view cannot outlive its bytes. All wire
offset/size arithmetic is checked before conversion to `Int`. Public APIs use
throwing validation and explicit traversal/nesting limits; unchecked operations,
if profiling proves they are needed, remain internal.

## Commit and verification policy

- Each numbered task below is one reviewable commit. A commit contains its tests
  and documentation and leaves `swift test` green. Mechanical fixture refreshes
  may be a separate immediately-following commit.
- Every upstream-derived test records the upstream commit and source test name in
  a test comment or manifest. Port behavior and edge cases, not C++ implementation
  details.
- CI has three layers: Swift-only tests on every change; committed golden-vector
  tests on every change; and pinned C++ differential/interoperability tests in a
  scheduled and release job.
- A task is complete only when its stated verification passes under Address
  Sanitizer where supported. Parser/decoder tasks also add malformed-input and
  fuzz seeds.
- Avoid snapshotting generated Swift as the only assertion. Compile it, exercise
  it, and check deterministic regeneration separately.

## Test-oracle design

The language-agnostic [`kaos/capnp_test`](https://github.com/kaos/capnp_test)
contract is the primary end-to-end serialization/code-generation acceptance
interface. Its harness invokes one implementation-owned executable for each
`decode <case>` and `encode <case>` operation, comparing through the reference
`capnp` tool. We will pin commit
`9aad1331857d2b02158cffdba4d664f71f7f81de`, run its files unmodified, and
implement the contract in `capnp-test-swift`.

The stock repository is a foundation rather than a complete conformance suite:
its last code change was in 2013, its TODO explicitly calls for more tests, and
it currently exercises four cases (`simpleTest`, `textListTypeTest`,
`uInt8DefaultValueTest`, and `constTest`) in encode/decode directions. Therefore
we retain the protocol but add versioned local profiles covering the current
upstream schemas, packed/streamed data, malformed input, evolution, and RPC.
Changes suitable for all language plugins should be proposed upstream rather
than existing only in this repository.

Milestone 0 also creates `Tests/InteropFixtures/manifest.json`, mapping every fixture
to an upstream commit, schema, producing command, encoding (`flat`, `stream`, or
`packed`), and expected semantic value. A small upstream C++ fixture driver will:

1. emit reference messages for Swift to decode;
2. decode messages emitted by Swift and print a normalized semantic form;
3. run old-schema/new-schema evolution pairs; and
4. act as the opposite endpoint for RPC transcript and live interop tests.

The upstream suites are grouped as follows:

| Area | Primary upstream evidence |
| --- | --- |
| Wire/layout | `layout-test.c++`, `encoding-test.c++`, `message-test.c++`, `list-test` behavior in generated tests |
| Framing/packing | `serialize-test.c++`, `serialize-packed-test.c++`, `serialize-async-test.c++` |
| Ownership/canonical form | `orphan-test.c++`, `canonicalize-test.c++`, `fuzz-test.c++` |
| Schema/codegen | `test.capnp`, `test-import*.capnp`, `schema-test.c++`, `schema-loader-test.c++`, `dynamic-test.c++` |
| Compiler/evolution | `compiler/lexer-test.c++`, `compiler/type-id-test.c++`, `schema-parser-test.c++`, `compiler/evolution-test.c++` |
| Capabilities/RPC | `capability-test.c++`, `rpc-test.c++`, `rpc-twoparty-test.c++`, `ez-rpc-test.c++` |
| Plugin-level interop | `kaos/capnp_test` stock encode/decode suite plus this project's extended profiles |

## Milestone 0 — Foundation and executable specification

Exit gate: an empty implementation package builds on macOS and Linux, the
upstream baseline is immutable, and CI can prove fixture provenance.

### 0.1 Scaffold the Swift package

Create the target/product skeleton above, enable Swift 6 strict concurrency,
add placeholder tests, formatting/lint configuration, license, and supported
platform policy.

**Verify:** `swift build` and `swift test` on macOS and Linux; CI rejects target
cycles and accidental linkage to Cap'n Proto C/C++ libraries.

### 0.2 Pin and inventory upstream conformance sources

Record an exact `capnproto/capnproto` `master` SHA, the fixed `kaos/capnp_test`
SHA above, license notices, the relevant test files, schemas (`schema.capnp`,
`rpc.capnp`, `rpc-twoparty.capnp`, `test.capnp`, imports), and a feature-to-test
traceability manifest.

**Verify:** a script checks the SHA and hashes of imported fixtures; every
release-blocking feature has at least one upstream test source assigned.

### 0.3 Integrate the language-agnostic plugin test contract

Vendor the pinned `kaos/capnp_test` suite unchanged, including its license and
provenance, under `Tests/Conformance/capnp_test`, and add a
`capnp-test-swift` command with explicit dispatch for every stock test name. It
may initially return the harness-defined skip code for unfinished operations,
but must distinguish an intentional skip from a failure.

**Verify:** the unmodified harness discovers all four stock cases and reports
eight intentional skips; a fake known-good adapter demonstrates that both encode
and decode directions fail on byte/value corruption and pass on correct data.

### 0.4 Build the golden-vector oracle

Add reproducible scripts that use the pinned reference `capnp`/C++ implementation
to produce flat, stream-framed, packed, multi-segment, default-valued, union,
group, and nested-list fixtures. Commit only small deterministic outputs.

**Verify:** regenerating fixtures is byte-for-byte clean; the reference decoder
accepts every fixture and reports the expected normalized value.

### 0.5 Add test support, fuzzing, and benchmarks

Implement hex/word assertions, deterministic property generators, subprocess
interop helpers, fuzz targets, and baseline benchmarks for decode, traversal,
build, serialize, and packed I/O.

**Verify:** seeded property tests reproduce failures; each fuzz target accepts the
upstream fuzz corpus; benchmarks report results but do not gate correctness.

## Milestone 1 — Checked wire-format core

Exit gate: Swift safely reads hand-authored and upstream-produced segment arrays,
including every pointer/list form and adversarial bounds case.

### 1.1 Implement words, endian access, and checked arithmetic

Add 64-bit word indexing, little-endian scalar loads/stores, bit-field helpers,
alignment, and overflow-safe offset/range calculations without assuming host
alignment.

**Verify:** port `endian-test.c++`, fallback/reverse-endian vectors, and primitive
cases from `layout-test.c++`; test all integer boundaries and deliberately
unaligned byte buffers.

### 1.2 Decode struct and list pointers

Implement null, struct, and list pointer decoding, including void, bit, byte,
two-byte, four-byte, eight-byte, pointer, and inline-composite lists.

**Verify:** port the raw-pointer cases in `layout-test.c++`; decode C++ fixtures
for all primitive/list shapes in `TestAllTypes`; reject invalid tags, negative
targets, multiplication overflow, and out-of-segment ranges.

### 1.3 Decode far and double-far pointers

Add segment tables, landing pads, far pointers, and double-far pointers while
preserving traversal accounting across segments.

**Verify:** port the single-far, double-far, multi-segment, and malformed landing
pad cases from `layout-test.c++` and `encoding-test.c++`'s `AllTypesMultiSegment`.

### 1.4 Add the untyped reader API and resource limits

Create message/segment readers, untyped struct/list/text/data readers, root
access, nesting limits, traversal limits, and deterministic validation errors.

**Verify:** mirror reader and limit cases from `message-test.c++`,
`encoding-test.c++`, and `fuzz-test.c++`; no malformed corpus input traps, hangs,
or reads outside owned storage.

### 1.5 Implement schema-evolution reads

Support data/pointer section truncation, larger structs, primitive-list to
struct-list upgrades, default XOR semantics, and unknown enum/union values.

**Verify:** run the reader half of `compiler/evolution-test.c++` old/new schema
pairs in both directions and compare normalized output with C++.

## Milestone 2 — Builders, framing, and serialization

Exit gate: Swift can construct, mutate, serialize, and round-trip all core value
shapes in single- and multi-segment messages.

### 2.1 Implement arenas and allocation strategies

Add first-segment sizing, growing and fixed-size allocation strategies, segment
IDs, zero initialization, and deterministic segment output.

**Verify:** port allocation and segment-count assertions from `message-test.c++`
and the single/multi-segment pairs in `encoding-test.c++`; run under ASan.

### 2.2 Implement struct, blob, and primitive-list builders

Add root initialization, data/pointer field mutation, text/data terminators,
bit packing, list initialization, clear, and `has` semantics.

**Verify:** port `Encoding.AllTypes`, defaults/default initialization, list
defaults, empty lists, blobs, and primitive list cases from `encoding-test.c++`
and `blob-test.c++`; C++ decodes Swift output semantically identically.

### 2.3 Implement composite/nested lists, groups, and unions

Support inline-composite struct lists, nested lists, list upgrades, group
zeroing, discriminants, and unknown discriminant preservation.

**Verify:** port `SmallStructLists`, `Groups`, `InterleavedGroups`, `Unions`,
`UnionLayout`, `UnnamedUnion`, and `UnionDefault` from `encoding-test.c++`, plus
byte-level comparison for layout-sensitive vectors.

### 2.4 Implement deep copy, orphan, adopt, and disown

Add cross-message deep copy, orphan ownership, adoption constraints, and
recursive clearing without stack overflow.

**Verify:** port applicable `orphan-test.c++` cases and copy/upgrade cases from
`layout-test.c++`; property-test that copied graphs are independent and adopting
into an invalid arena fails safely.

### 2.5 Implement stream framing and scatter/gather output

Read/write the segment table format, padding, concatenated messages, partial
reads, and async byte-stream adapters.

**Verify:** port `serialize-test.c++` and applicable `serialize-async-test.c++`
cases; test every split point of representative frames and Swift↔C++ streams.

### 2.6 Implement packed encoding

Add streaming pack/unpack state machines, zero-word and literal runs, partial
input/output handling, and bounded expansion.

**Verify:** port all `serialize-packed-test.c++` vectors, exhaustively split input
at every byte boundary, and cross-decode randomized packed messages with C++.

### 2.7 Implement canonicalization

Add canonical size computation, single-segment canonical output, pointer/list
normalization, and canonical-form validation.

**Verify:** port `canonicalize-test.c++`; require idempotence and exact byte
equality with C++ canonical output for the shared fixture corpus.

## Milestone 3 — Typed API and compiler-plugin code generation

Exit gate: `capnp compile -o swift` can generate compiling Swift for the complete
stable schema language, using the upstream compiler as the frontend, and all
eight stock `kaos/capnp_test` encode/decode operations pass without skips.

### 3.1 Bootstrap schema metadata

Check in reviewed, deterministic Swift bindings for the pinned `schema.capnp`
and decode `CodeGeneratorRequest`. Document the bootstrap regeneration path.

**Verify:** decode requests for upstream `test.capnp`, imports, `rpc.capnp`, and
`rpc-twoparty.capnp`; re-encode them for byte/semantic comparison with C++.

### 3.2 Emit files, names, namespaces, and imports

Implement plugin stdin handling, requested-file selection, stable Swift
identifier escaping, nested scopes, import resolution, and deterministic output.

**Verify:** golden-test requests covering keyword collisions and
`test-import*.capnp`; run generation twice and compile output in a clean package.

### 3.3 Generate structs, enums, constants, and defaults

Emit typed `Reader`/`Builder` views, scalar/blob/struct/list accessors, enums,
constants, default XOR values, presence tests, and root helpers.

**Verify:** generate upstream `test.capnp`, port `Encoding.AllTypes`, `Defaults`,
`ListDefaults`, and unknown enum cases to use only public generated APIs, and run
Swift-writes/C++-reads plus C++-writes/Swift-reads. Generate the stock
`kaos/capnp_test/test.capnp` and require `capnp-test-swift` to pass all stock
encode/decode cases without skips.

### 3.4 Generate unions, groups, nested types, and generic/AnyPointer APIs

Emit discriminated Swift enums/views without losing unknown tags; support groups,
nested declarations, generic parameters, `AnyPointer`, and type-erased access.

**Verify:** generated versions of upstream union/group tests pass; cover schemas
used by `any-test.c++`, `dynamic-test.c++`, and compiler generics tests; generated
code compiles with strict concurrency diagnostics enabled.

### 3.5 Generate interface APIs and codegen diagnostics

Emit capability client/server protocols, method descriptors, param/result types,
inheritance, streaming markers, and source-located errors for unsupported schema
constructs.

**Verify:** compile all interfaces in upstream `test.capnp` and `rpc.capnp`; API
shape supports the service implementations used by `capability-test.c++` and
`rpc-test.c++`; malformed requests fail without partial output.

### 3.6 Add SwiftPM plugin integration

Provide an opt-in build-tool plugin, correct incremental inputs/outputs, import
paths, module naming configuration, and a checked-in example package.

**Verify:** clean and incremental `swift build` regenerate only when schemas or
imports change; the example runs on macOS and Linux; paths containing spaces work.

## Milestone 4 — Reflection and dynamic values

Exit gate: applications and the compiler can inspect schemas and manipulate
messages without generated types.

### 4.1 Implement schema objects and registry

Model files, structs, enums, interfaces, constants, annotations, dependencies,
brand bindings, and ID/name lookup with validation.

**Verify:** port `schema-test.c++` lookup, dependency, nested-node, union, and
method tests against bootstrapped upstream schemas.

### 4.2 Implement schema loading and compatibility checks

Load serialized nodes incrementally, resolve dependencies, reject invalid graphs,
and calculate read/write compatibility.

**Verify:** port `schema-loader-test.c++`, including invalid node/layout cases and
replacement behavior; rerun all upstream evolution pairs.

### 4.3 Implement dynamic readers and builders

Add dynamic structs, lists, enums, capabilities, `AnyPointer`, defaults, unions,
and conversions to/from typed views.

**Verify:** port `dynamic-test.c++` and dynamic helpers from `test-util.c++`;
dynamically round-trip every field in `TestAllTypes` and compare with typed APIs.

### 4.4 Implement deterministic diagnostics/stringification

Provide value/schema descriptions useful for debugging and normalized interop
output, without making textual serialization a core dependency.

**Verify:** port applicable `stringify-test.c++` cases; randomized typed and
dynamic views stringify identically and never recurse past configured limits.

## Milestone 5 — Local capabilities and RPC state-machine foundation

Exit gate: capability calls, promises, cancellation, and pipelining work over a
deterministic in-memory transport before network complexity is introduced.

### 5.1 Implement the local capability model

Add typed clients, servers, request/response contexts, local dispatch,
inheritance/casting, null/broken capabilities, and structured remote errors.

**Verify:** port local-call, inheritance, null, broken, and exception behavior
from `capability-test.c++`; generated test services execute end to end.

### 5.2 Implement promise capabilities and pipelining

Represent unresolved capabilities/results with Swift concurrency, queue calls in
order, resolve redirects, and expose generated pipeline accessors.

**Verify:** port pipeline, call-order, resolve, and promise-cap tests from
`capability-test.c++` and `rpc-test.c++`; prove calls issue before the parent result
arrives using a deterministic test clock.

### 5.3 Implement cancellation and lifetime semantics

Tie task cancellation to questions/answers, release exports/imports exactly once,
handle abandoned results, and avoid retain cycles across capability graphs.

**Verify:** port cancel, never-return, handle/destructor, disconnect, and embargo
lifetime cases from `rpc-test.c++`; leak checks return tables to zero.

### 5.4 Define transport and connection test harnesses

Create an ordered async message transport, in-memory duplex transport, disconnect
semantics, tracing hooks, and deterministic fault injection/backpressure.

**Verify:** fragment/coalesce every message boundary, inject EOF/errors at each
state transition, and show no suspended continuation or RPC table leaks.

## Milestone 6 — Cap'n Proto RPC wire protocol

Exit gate: a Swift client and server interoperate live with the pinned C++
two-party implementation across the release-blocking RPC matrix.

### 6.1 Bootstrap and validate RPC protocol schemas

Generate bindings for `rpc.capnp` and `rpc-twoparty.capnp`; validate all inbound
IDs, table transitions, and message variants before mutation.

**Verify:** decode/re-encode captured C++ RPC messages; malformed variants and
out-of-range IDs produce protocol errors, not traps.

### 6.2 Implement bootstrap, call, return, finish, and release

Build question/answer and import/export tables, target transforms, parameter cap
tables, result adoption, exception returns, and reference accounting.

**Verify:** port the corresponding `rpc-test.c++` bootstrap/basic-call,
cap-passing, exception, finish/release, and disconnect tests; table invariants are
asserted after every scripted transcript.

### 6.3 Implement resolve and promise pipelining on the wire

Support promised-answer targets, sender promises, resolution to capability or
error, redirect chains, and loop detection.

**Verify:** port promised-answer, pipeline, delayed resolve, resolve-to-error, and
call-order cases from `rpc-test.c++`; Swift and C++ endpoints work in both roles.

### 6.4 Implement disembargo and ordering barriers

Implement sender/receiver-loopback embargoes and ordering guarantees when a
remote promise resolves locally.

**Verify:** port embargo/disembargo and call-order regressions from
`rpc-test.c++`; adversarial reordered transport events cannot violate call order.

### 6.5 Implement cancellation, tail calls, and streaming methods

Propagate cancellation races correctly, implement `takeFromOtherQuestion` tail
calls, and enforce streaming call flow control.

**Verify:** port cancellation, tail-call/tail-callee, and streaming tests from
`rpc-test.c++`, including server errors and disconnect at every race point.

### 6.6 Implement the two-party network and SwiftNIO adapter

Add client/server side identities, bootstrap flow, stream framing, write
serialization, backpressure, half-close, and clean shutdown over TCP/Unix sockets.

**Verify:** port `rpc-twoparty-test.c++` and applicable `ez-rpc-test.c++`; run a
four-way live matrix (Swift→Swift, Swift→C++, C++→Swift, C++→C++) for control.

### 6.7 Complete RPC conformance and soak testing

Add deterministic transcript replay, randomized legal protocol sequences,
disconnect/reconnect stress, large-message limits, and long-running capability
churn tests.

**Verify:** the mapped release-blocking `capability-test.c++`, `rpc-test.c++`, and
`rpc-twoparty-test.c++` cases are all green or carry reviewed waivers; a 24-hour
ASan/TSan soak has no crashes, races, growth, or leaked table entries.

## Milestone 7 — Self-contained Swift schema compiler

Exit gate: normal users no longer need an external `capnp` executable; its output
IR is equivalent to the pinned compiler for the supported stable language.

### 7.1 Implement lexer and source diagnostics

Tokenize identifiers, literals, comments, punctuation, and Unicode/source
positions with recoverable, deterministic diagnostics.

**Verify:** port `compiler/lexer-test.c++`; fuzz arbitrary bytes and require no
trap, hang, or invalid source range.

### 7.2 Implement parser and AST

Parse files, declarations, types, values, annotations, groups, unions, generics,
and interfaces with useful multi-error recovery.

**Verify:** port the syntax/error corpus from `schema-parser-test.c++`; parse all
pinned upstream `.capnp` files used by the project.

### 7.3 Implement imports, names, IDs, and generic resolution

Resolve absolute/relative imports, nested names, aliases, brands, annotations,
and deterministic type IDs with cycle diagnostics.

**Verify:** port `test-import*.capnp`, compiler generics cases, and
`compiler/type-id-test.c++`; compare resolved IDs/dependencies with C++ IR.

### 7.4 Implement layout and semantic translation

Assign ordinals, data/pointer offsets, discriminants, groups, method param/result
structs, defaults, and schema-evolution constraints, producing `schema.capnp`
nodes and `CodeGeneratorRequest`.

**Verify:** compare normalized compiler IR with C++ for `test.capnp`, RPC schemas,
and an evolution corpus; all `compiler/evolution-test.c++` pairs behave equally.

### 7.5 Ship `capnp-swift` and switch the build plugin

Add `compile`, `id`, and schema-inspection commands; make the SwiftPM plugin use
the native frontend by default while retaining plugin-protocol compatibility.

**Verify:** native and upstream frontends generate byte-identical normalized IR
and equivalent Swift; build all examples with `capnp` absent from `PATH`.

## Milestone 8 — Security, performance, and 1.0 release

Exit gate: documented compatibility, stable API, audited resource limits, and
reproducible releases on supported platforms.

### 8.1 Close the upstream conformance ledger

Review every mapped upstream test and classify it as ported, covered by
differential testing, not applicable, or deferred with rationale.

**Verify:** CI fails on an unclassified manifest entry; zero unexplained failures
remain in serialization, codegen, schema evolution, capability, or two-party RPC.
The stock `kaos/capnp_test` suite and all release-profile extensions pass without
skips.

### 8.2 Harden hostile-input boundaries

Audit integer conversions, traversal accounting, nesting, packed expansion,
segment counts, allocation ceilings, compiler complexity, RPC table growth, and
error redaction.

**Verify:** sanitizers, Swift fuzzers, upstream fuzz seeds, mutation corpora, and
allocation-failure tests pass; each published limit has a boundary regression.

### 8.3 Optimize measured hot paths

Profile before changing ownership/layout; optimize endian loads, pointer walks,
arena allocation, copies, packing, generated accessors, and RPC tables while
keeping checked APIs the default.

**Verify:** no conformance regressions; publish reproducible comparisons against
C++ and at least one mature non-C++ implementation for representative workloads;
CI flags major regressions against stored baselines.

### 8.4 Stabilize API, documentation, and examples

Complete DocC, serialization/RPC tutorials, generated API guide, migration and
security guides, semantic-versioning policy, and examples including address book,
schema evolution, calculator, and pipelined RPC.

**Verify:** documentation snippets compile in CI; examples interoperate with C++;
public API review finds no accidental exposure of internal wire types.

### 8.5 Release 1.0

Tag reproducible source releases, publish checksums and compatibility matrix, and
document the upstream baseline plus known deviations and performance results.

**Verify:** clean consumers build from the tag on supported macOS/Linux Swift
versions; generated sources reproduce; the full Swift-only, golden, differential,
RPC interop, sanitizer, and soak suites pass from the release candidate.

## Follow-on milestones

After 1.0, prioritize text/JSON codecs (`serialize-text-test.c++`, JSON tests),
persistent capabilities and reconnect, membranes, WebSocket RPC, additional
transports, Windows, distributed/three-party handoff, and upstream v2 tracking.
Each should begin by extending the conformance ledger before implementation.

## Primary references

- Encoding specification: <https://capnproto.org/encoding.html>
- RPC protocol specification: <https://capnproto.org/rpc.html>
- Compiler plugin/tool contract: <https://capnproto.org/capnp-tool.html>
- Stable upstream implementation and tests:
  <https://github.com/capnproto/capnproto/tree/master/c%2B%2B/src/capnp>
- Upstream compiler tests:
  <https://github.com/capnproto/capnproto/tree/master/c%2B%2B/src/capnp/compiler>
- Language-agnostic plugin test harness: <https://github.com/kaos/capnp_test>
- Schema IR: <https://github.com/capnproto/capnproto/blob/master/c%2B%2B/src/capnp/schema.capnp>
- RPC schemas: <https://github.com/capnproto/capnproto/blob/master/c%2B%2B/src/capnp/rpc.capnp>
