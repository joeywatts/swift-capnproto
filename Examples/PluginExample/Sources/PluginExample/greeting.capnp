@0xeefb4c3d70f18de3;

using Metadata = import "Schemas/common.capnp".Metadata;

struct Greeting {
  text @0 :Text;
  metadata @1 :Metadata;
}
