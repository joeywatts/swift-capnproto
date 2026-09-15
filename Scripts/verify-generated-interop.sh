#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$($root/Scripts/prepare-reference-capnp.sh)"
capnp="$prefix/bin/capnp"
schema="$root/Tests/Conformance/capnp_test/test.capnp"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$root"
swift build --product capnp-test-swift
bin="$root/.build/debug/capnp-test-swift"

"$capnp" encode "$schema" TestAllTypes >"$work/cpp-all-types.bin" <<'EOF'
(boolField = true,
 int8Field = -8, int16Field = -16, int32Field = -123456, int64Field = -64,
 uInt8Field = 8, uInt16Field = 16, uInt32Field = 32,
 uInt64Field = 18446744073709551615,
 float32Field = 1.25, float64Field = -2.5,
 textField = "typed", dataField = 0x"00 01 ff",
 structField = (textField = "nested"), enumField = grault,
 voidList = [void, void], boolList = [true, false, true],
 int8List = [-1, 2], int16List = [-3, 4], int32List = [1, -2, 3],
 int64List = [-5, 6], uInt8List = [7, 8], uInt16List = [9, 10],
 uInt32List = [11, 12], uInt64List = [13, 14],
 float32List = [1.5, -2.5], float64List = [3.5, -4.5],
 textList = ["one", "two"], dataList = [0x"01 02", 0x"03"],
 structList = [(textField = "element")], enumList = [foo, garply],
 interfaceList = [void])
EOF

"$bin" roundtrip allTypesInterop \
  <"$work/cpp-all-types.bin" >"$work/swift-roundtrip-all-types.bin"
"$bin" encode allTypesInterop >"$work/swift-all-types.bin"
"$capnp" decode --short "$schema" TestAllTypes \
  <"$work/cpp-all-types.bin" >"$work/cpp-all-types.txt"
"$capnp" decode --short "$schema" TestAllTypes \
  <"$work/swift-roundtrip-all-types.bin" >"$work/swift-roundtrip-all-types.txt"
"$capnp" decode --short "$schema" TestAllTypes \
  <"$work/swift-all-types.bin" >"$work/swift-all-types.txt"
diff -u "$work/cpp-all-types.txt" "$work/swift-roundtrip-all-types.txt"
diff -u "$work/cpp-all-types.txt" "$work/swift-all-types.txt"

"$capnp" encode "$schema" TestDefaults >"$work/cpp-defaults.bin" <<'EOF'
()
EOF
"$bin" roundtrip defaultsInterop \
  <"$work/cpp-defaults.bin" >"$work/swift-roundtrip-defaults.bin"
"$bin" encode defaultsInterop >"$work/swift-defaults.bin"
"$capnp" decode --short "$schema" TestDefaults \
  <"$work/cpp-defaults.bin" >"$work/cpp-defaults.txt"
"$capnp" decode --short "$schema" TestDefaults \
  <"$work/swift-roundtrip-defaults.bin" >"$work/swift-roundtrip-defaults.txt"
"$capnp" decode --short "$schema" TestDefaults \
  <"$work/swift-defaults.bin" >"$work/swift-defaults.txt"
diff -u "$work/cpp-defaults.txt" "$work/swift-roundtrip-defaults.txt"
diff -u "$work/cpp-defaults.txt" "$work/swift-defaults.txt"

echo "generated TestAllTypes and list defaults interoperate in both directions"
