@0xc8c8ad92f4b8e62d;

using Cxx = import "/capnp/c++.capnp";
$Cxx.namespace("SwiftCapnpFixtures");

struct Defaults {
  boolValue @0 :Bool = true;
  intValue @1 :Int32 = -123;
}

struct Fixture {
  name @0 :Text;
  defaults @1 :Defaults;

  union {
    number @2 :Int32;
    label @3 :Text;
  }

  details :group {
    enabled @4 :Bool;
    count @5 :UInt16;
  }

  nested @6 :List(List(UInt16));
}
