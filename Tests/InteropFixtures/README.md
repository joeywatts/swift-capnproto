# Interoperability fixtures

These small binary files are generated and decoded by a C++ oracle built from
the exact Cap'n Proto revision in `Tests/Upstream/BASELINES`. They cover an
unframed single segment (`flat`), stream framing, packing, multiple segments,
default values, a union, a group, and nested lists.

Regenerate the committed files with:

```sh
Scripts/generate-fixtures.sh
```

Verify byte-for-byte reproducibility and normalized semantic output with:

```sh
Scripts/verify-fixtures.sh
```

The first invocation builds the pinned C++ oracle under `.build`; that build is
development-only and is never linked by a Swift package target.
