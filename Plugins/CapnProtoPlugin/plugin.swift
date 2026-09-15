import PackagePlugin

@main
struct CapnProtoPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        []
    }
}
