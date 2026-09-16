# SwiftPM build-tool plugin

Consumer targets opt in to schema generation by depending on the runtime and
attaching `CapnProtoPlugin`:

```swift
.executableTarget(
    name: "MyService",
    dependencies: [.product(name: "CapnProto", package: "swift-capnproto")],
    plugins: [.plugin(name: "CapnProtoPlugin", package: "swift-capnproto")]
)
```

Place `.capnp` sources anywhere below the target directory. For every schema,
the plugin declares one `.capnp.swift` output under its work directory. All
schemas found in the target and configured import roots are declared as inputs,
so unrelated source changes do not rerun code generation while schema and import
changes do.

The plugin invokes the package-built, self-contained `capnp-swift` compiler.
Consumers do not need the upstream `capnp` executable, and generated programs
do not link C or C++ libraries.

An optional `.capnp-swift.json` at the target root configures import roots and
asserts the intended Swift module name:

```json
{
  "moduleName": "MyService",
  "importPaths": ["Schemas", "../SharedSchemas"]
}
```

Import paths are relative to the target directory. `moduleName` must equal the
SwiftPM target name because generated files compile directly into that module.
Add the JSON file and schema paths to the target's `exclude` list so SwiftPM
does not report them as unhandled resources. The plugin still discovers
excluded schemas directly beneath the target directory.

[`Examples/PluginExample`](../Examples/PluginExample) is a runnable package with
a nested import. `Scripts/verify-swiftpm-plugin.sh` copies it to a path containing
spaces and verifies clean generation, no-op incremental builds, import-triggered
regeneration, compilation, and execution.
