# Supported platforms

The runtime libraries support Swift 6 language mode with strict concurrency
checking on:

- macOS 13 or newer;
- iOS and iPadOS 17 or newer;
- tvOS 17 or newer;
- watchOS 10 or newer;
- visionOS 1 or newer; and
- Linux on AArch64 and x86-64.

`CapnProto`, `CapnProtoSchema`, and `CapnProtoRPC` are pure Swift. The optional
`CapnProtoNIO` product supplies SwiftNIO TCP and Unix-domain-socket transports
and is cross-compiled alongside the other runtime libraries for every supported
Apple platform. App sandboxing and platform networking policy still determine
which socket endpoints an application may open at runtime.

The `CapnProtoCompiler` library, command-line executables, and
`CapnProtoPlugin` build tool are intended to run on the macOS or Linux
development host. The Swift files they generate can be compiled into apps on
all of the runtime platforms above. Consumers therefore do not need the Cap'n
Proto C or C++ libraries on their app targets; reference tools are used only as
development-time interoperability oracles.

Continuous integration builds and tests on macOS and Linux and cross-compiles
the complete runtime-library dependency graph for Apple simulators. The iOS
simulator build covers both iPhone and iPad application destinations because
they use the same iOS SDK and target ABI.
