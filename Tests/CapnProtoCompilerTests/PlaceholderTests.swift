import Testing
@testable import CapnProtoCompiler

@Test func compilerTargetLoads() {
    #expect(CapnProtoCompilerRuntime.isImplemented == false)
}
