# swift-capnproto

`swift-capnproto` is a planned pure Swift implementation of
[Cap'n Proto](https://capnproto.org/), including serialization, schema-driven
code generation, reflection, and capability-based RPC.

The project is currently in its foundation phase. The implementation sequence,
commit boundaries, and upstream-informed verification criteria are described in
[ROADMAP.md](ROADMAP.md).

## Intended products

- `CapnProto`: checked wire-format readers/builders and standard/packed
  serialization.
- `CapnProtoSchema`: schema metadata, reflection, and dynamic values.
- `CapnProtoRPC`: capability APIs and the RPC protocol state machine.
- `CapnProtoNIO`: optional SwiftNIO networking support.
- `CapnProtoCompiler`, `capnpc-swift`, and `capnp-swift`: generated Swift
  bindings and an eventually self-contained schema compiler.

No shipped target will link the Cap'n Proto C++ implementation. The reference
`capnp` tools in the development shell are used only to generate fixtures and
verify wire and RPC interoperability.

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
```

## Compatibility testing

End-to-end serialization and generated-code interoperability will implement the
language-neutral [`kaos/capnp_test`](https://github.com/kaos/capnp_test)
encode/decode contract. Lower-level behavior and RPC verification will be mapped
to the pinned tests and schemas from the reference
[`capnproto/capnproto`](https://github.com/capnproto/capnproto) repository.

## License

The project is available under the MIT License. Imported test fixtures retain
their original notices and provenance.
