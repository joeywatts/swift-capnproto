# Schema bootstrap

`Sources/CapnProtoSchema/SchemaCapnp.swift` is the reviewed bootstrap binding for
the `schema.capnp` file at the Cap'n Proto revision pinned in
`Tests/Upstream/BASELINES`. It is hand-maintained so the first invocation of
`capnpc-swift` does not depend on generated Swift already existing.

To review a bootstrap change:

1. Run `Scripts/prepare-reference-capnp.sh` and inspect the pinned
   `install/include/capnp/schema.capnp` and generated `schema.capnp.h`.
2. Compare every changed ordinal, discriminant, data offset, pointer index, and
   default XOR value with the generated C++ reader accessors.
3. Run `Scripts/verify-schema-bootstrap.sh`. The script creates compiler-plugin
   requests for the upstream test/import and RPC schemas, decodes them with the
   Swift binding, deep-copies every request field, and asks the pinned C++ tool to
   decode the copy as `schema.CodeGeneratorRequest`.

Once the Swift generator can regenerate this file, deterministic generated output
will additionally be compared against the reviewed bootstrap file. The checked-in
bootstrap remains the trust anchor; generation is never required to build it.
