import CapnProto

let message = try MessageBuilder()
_ = try message.initRootStruct(dataWords: 0, pointerCount: 0)
print(try message.framedBytes.count)
