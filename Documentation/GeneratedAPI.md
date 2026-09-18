# Generated Swift API

`capnpc-swift` emits namespace enums containing typed `Reader` and `Builder`
views. Struct and list storage remains owned by the underlying message, so a
generated view is inexpensive and preserves Cap'n Proto's evolution rules.
Reader and client views conform to `Sendable`; mutable builder views remain
task-confined because they share mutable message storage.

Every generated non-group struct provides `readRoot(from:)` and
`initRoot(in:)`. The root reader rejects trailing frames. Its overload accepting
`FramingOptions` and `ReaderOptions` lets applications apply separate wire-size
and traversal limits at untrusted input boundaries.

Union-bearing structs expose a throwing `which` view. Its cases carry the
selected value, and `.unknown(UInt16)` preserves discriminants introduced by a
newer schema. Builder selection clears only storage owned by union members;
ordinary fields and packed bits outside the union are retained. Groups are
nested reader/builder views over their parent struct rather than separately
allocated objects.

Every non-group struct also emits a `Pointer` adapter. Generic schemas expose a
`Generic<...>` facade whose parameters conform to `CapnProtoPointerType`.
Built-in adapters cover `AnyPointer`, `AnyStruct`, `AnyList`, `Text`, and `Data`,
while generated struct `Pointer` adapters provide typed struct bindings. The
ordinary `Reader` and `Builder` remain the explicit type-erased API for unbound
or dynamically selected brands.

`AnyPointerReader` can be interpreted as a struct, list, text, or data value.
`AnyPointerBuilder` can deep-copy those values across messages or initialize new
struct and list storage. All casts and mutations validate the wire kind and
throw `CapnProtoError` on mismatch.

Regenerate the checked advanced fixture with:

```sh
Scripts/generate-advanced-swift.sh
```

`Scripts/verify-swift-codegen.sh` separately checks deterministic regeneration,
clean-package compilation, and strict Swift 6 typechecking of the complete
pinned upstream `test.capnp` schema.

## Capability interfaces

Generated interfaces contain a `Client`, an inheritable `Server` protocol, and
stable `CapabilityMethodDescriptor` values. Anonymous parameter and result
structs are emitted as nested types. Streaming methods return `Void` from the
client and omit a results builder from the server signature; their descriptor's
`isStreaming` flag remains available to dispatch code.

Each interface provides `client(_:)` to bind a generated server to local
dispatch. A derived client exposes typed views of its inherited interfaces.
Non-streaming methods also provide a `...Request` form returning a generated
pipeline view: callers can await its typed `response()`, cancel it, or immediately
use generated capability-field accessors while the parent result is unresolved.

`CapabilityClient` delegates calls to an application- or RPC-runtime-provided
`CapabilityCallTarget`. It supports null and broken clients, structured remote
exceptions, checked interface casts, promise resolution, and ordered queued calls.
Capability fields and lists accept clients backed by a capability-table index.
The runtime's reference-counted table releases entries exactly once. RPC wire
dispatch and network capability-table synchronization remain Milestone 6 work.
