import CapnProto
import Foundation

let message = try MessageBuilder()
let person = try message.initRootStruct(dataWords: 1, pointerCount: 1)
try person.setInteger(atByte: 0, to: UInt32(42))
_ = try person.setTextField(at: 0, to: "Ada")

let decoded = try MessageFraming.decodePrefix(message.framedBytes).reader().rootStruct()
let name = try decoded.textField(at: 0).string ?? ""
let id = try decoded.integer(atByte: 0, as: UInt32.self)
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write" {
    try Data(message.framedBytes).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("\(id): \(name)")
