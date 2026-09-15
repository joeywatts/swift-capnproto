import CapnProto
import Foundation

let message = try MessageBuilder()
let greeting = try Greeting.initRoot(in: message)
try greeting.setText("hello from generated Swift")
try greeting.initMetadata().setSequence(3)

let decoded = try Greeting.readRoot(from: message.framedBytes)
print("\(try decoded.text) #\(try decoded.metadata.sequence)")
