import CapnProto

// The old writer knows one UInt32. The new reader safely treats its added field
// as the schema default because the old data section is truncated.
let oldMessage = try MessageBuilder()
let old = try oldMessage.initRootStruct(dataWords: 1, pointerCount: 0)
try old.setInteger(atByte: 0, to: UInt32(7))

let newView = try oldMessage.asReader().rootStruct()
let original = try newView.integer(atByte: 0, as: UInt32.self)
let added = try newView.integer(atByte: 8, as: UInt32.self, default: 99)
print("original=\(original) added=\(added)")
