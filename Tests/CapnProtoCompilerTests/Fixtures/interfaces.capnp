@0xa5f236b9b842bbbd;

using Advanced = import "advanced.capnp".Advanced;

interface Base {
  ping @0 (value :UInt32) -> (text :Text);
}

interface Child extends(Base) {
  call @0 (request :Advanced(Text)) -> (response :Advanced(Text));
  streamIt @1 (chunk :Data) -> stream;
}

struct CapabilityHolder {
  service @0 :Child;
  services @1 :List(Child);
}
