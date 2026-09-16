fn main() {
    capnpc::CompilerCommand::new()
        .src_prefix("..")
        .file("../benchmark.capnp")
        .run()
        .expect("compile benchmark schema");
}
