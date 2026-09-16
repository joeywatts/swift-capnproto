# swift-capnproto

`swift-capnproto` is a pure Swift implementation of
[Cap'n Proto](https://capnproto.org/), including serialization, schema-driven
code generation, reflection, and capability-based RPC.

The project has completed the checked wire-format, serialization, typed
code-generation, reflection, and two-party RPC milestones. It generates Swift
readers, builders, enums, defaults, unions, groups, generic pointer adapters, and
capability clients, servers, dispatchers, and pipeline views; the opt-in SwiftPM
plugin integrates `.capnp` files into consumer targets. Readers enforce nesting
and traversal limits, while framing and packed decoders bound attacker-controlled
expansion. The implementation sequence, commit boundaries, and upstream-informed
verification criteria are described in [ROADMAP.md](ROADMAP.md).

## Intended products

- `CapnProto`: checked wire-format readers/builders and standard/packed
  serialization.
- `CapnProtoSchema`: schema metadata, reflection, and dynamic values.
- `CapnProtoRPC`: capability APIs and the RPC protocol state machine.
- `CapnProtoNIO`: optional SwiftNIO networking support.
- `CapnProtoCompiler`, `capnpc-swift`, and `capnp-swift`: generated Swift
  bindings and a self-contained schema compiler.

No shipped target will link the Cap'n Proto C++ implementation. The reference
`capnp` tools in the development shell are used only to generate fixtures and
verify wire and RPC interoperability.

Compile schemas directly with the native frontend:

```sh
swift run capnp-swift compile -I Schemas --src-prefix Schemas -o Generated Schemas/app.capnp
swift run capnp-swift inspect -I Schemas Schemas/app.capnp
swift run capnp-swift id 0xdeadbeefdeadbeef ChildName
```

`compile` can also write its framed `CodeGeneratorRequest` with
`--request-output`, and `normalize-request` emits a stable wire-layout summary
used by the differential compiler tests.

## Development environment

The repository provides a Nix flake and direnv configuration. Enter the shell
automatically with:

```sh
direnv allow
```

Or enter it directly:

```sh
nix develop
```

The shell supports Apple Silicon macOS and ARM64/x86-64 Linux. It supplies Cap'n
Proto's reference tools, CMake, Ninja, Git, and pkg-config. It supplies Swift on
Linux; macOS uses the Swift toolchain installed with Xcode or the Xcode
command-line tools.

The normal validation entry points are:

```sh
swift test
Scripts/check-package-boundaries.sh
Scripts/verify-swift-codegen.sh
Scripts/verify-swiftpm-plugin.sh
Scripts/verify-fuzz-targets.sh
Scripts/verify-rpc-interop.sh
RPC_SOAK_SECONDS=60 Scripts/run-rpc-soak.sh
Scripts/run-benchmarks.sh
```

The stable 1.0 documentation includes the [serialization guide](Sources/CapnProto/CapnProto.docc/SerializationTutorial.md),
[RPC tutorial](Documentation/RPCTutorial.md), [generated API guide](Documentation/GeneratedAPI.md),
[migration policy](Documentation/Migration.md), and [security limits](Documentation/Security.md).
Runnable address-book, evolution, calculator, and pipelined-RPC examples live
under `Examples/`; `Scripts/verify-examples.sh` compiles and exercises all four.

## Compatibility testing

End-to-end serialization and generated-code interoperability will implement the
language-neutral [`kaos/capnp_test`](https://github.com/kaos/capnp_test)
encode/decode contract. Lower-level behavior and RPC verification will be mapped
to the pinned tests and schemas from the reference
[`capnproto/capnproto`](https://github.com/capnproto/capnproto) repository.
The exact revisions, imported sources, and feature traceability are recorded in
`Tests/Upstream`; validate them with `Scripts/verify-upstream.sh`.

## License

The project is available under the MIT License. Imported test fixtures retain
their original notices and provenance.
