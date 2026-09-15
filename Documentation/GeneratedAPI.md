# Generated Swift API

`capnpc-swift` emits namespace enums containing typed `Reader` and `Builder`
views. Struct and list storage remains owned by the underlying message, so a
generated view is inexpensive and preserves Cap'n Proto's evolution rules.

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
