@0xec9f96f731f7ef06;

struct Advanced(T) {
  nestedList @0 :List(List(UInt16));
  payload @1 :AnyPointer;
  typed @2 :T;
  anyStruct @11 :AnyStruct;
  anyList @12 :AnyList;
  nestedStructList @13 :List(List(Nested));

  union {
    number @3 :Int32;
    text @4 :Text;
    details :group {
      flag @5 :Bool;
      note @6 :Text;
    }
  }

  struct Nested {
    value @0 :UInt64;
  }

  nested @7 :Nested;
  metadata :group {
    count @8 :UInt32;
    label @9 :Text;
  }

  outsideFlag @10 :Bool;
}

struct Branded {
  textBox @0 :Advanced(Text);
}
