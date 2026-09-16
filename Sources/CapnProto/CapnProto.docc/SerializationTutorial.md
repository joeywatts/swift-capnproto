# Serialization tutorial

Create a builder, initialize its root, and serialize stream framing:

```swift
let message = try MessageBuilder()
let root = try message.initRootStruct(dataWords: 1, pointerCount: 1)
try root.setInteger(atByte: 0, to: UInt32(42))
try root.setTextField(at: 0, to: "Ada")
let bytes = try message.framedBytes
```

At an input boundary, select explicit resource limits before reading:

```swift
let frame = try MessageFraming.decodePrefix(
    bytes, options: FramingOptions(maximumSegments: 16, maximumTotalWords: 65_536))
let reader = try frame.reader(
    options: ReaderOptions(traversalLimitInWords: 65_536, nestingLimit: 32))
```

Use `PackedEncoding.pack` only around complete word-aligned content and bound
unpacking with `maximumOutputBytes`.
