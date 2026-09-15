@0xca8b17ebe1c072c5;

using Base = import "import-base.capnp";

struct UsesImport {
  value @0 :Base.ImportedValue;
}
