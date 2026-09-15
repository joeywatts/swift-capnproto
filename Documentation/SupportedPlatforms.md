# Supported platforms

The package supports Swift 6 language mode with strict concurrency checking on:

- macOS 13 or newer on Apple Silicon;
- Linux on AArch64 and x86-64.

Continuous integration builds and tests both macOS and Linux. The core package
does not link against the Cap'n Proto C or C++ libraries; reference tools are
development-only interoperability oracles.
