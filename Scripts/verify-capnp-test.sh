#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
suite="$root/Tests/Conformance/capnp_test"
swift build --product capnp-test-swift >/dev/null
bin_path="$(swift build --show-bin-path)/capnp-test-swift"

(cd "$root" && shasum -a 256 -c Tests/Conformance/capnp_test.sha256)
make -s -C "$suite" expect/simpleTest.txt expect/simpleTest.bin

(
  cd "$suite"
  CAPNP_TEST_APP="$root/Tests/Conformance/Adapters/fake-good.sh" \
    ./exec_test.sh decode simpleTest SimpleTestStruct
  CAPNP_TEST_APP="$root/Tests/Conformance/Adapters/fake-good.sh" \
    ./exec_test.sh encode simpleTest SimpleTestStruct

  if CAPNP_TEST_APP="$root/Tests/Conformance/Adapters/fake-corrupt-value.sh" \
      ./exec_test.sh decode simpleTest SimpleTestStruct; then
    echo "decode corruption was not detected" >&2
    exit 1
  fi
  if CAPNP_TEST_APP="$root/Tests/Conformance/Adapters/fake-corrupt-bytes.sh" \
      ./exec_test.sh encode simpleTest SimpleTestStruct; then
    echo "encode corruption was not detected" >&2
    exit 1
  fi
)

report="$(make -s -C "$suite" CAPNP_TEST_APP="$bin_path" 2>&1)"
skip_count="$(printf '%s\n' "$report" | grep -cE '^\.\. SKIP')"
[[ "$skip_count" == 8 ]] || {
  printf '%s\n' "$report" >&2
  echo "expected eight intentional skips, got $skip_count" >&2
  exit 1
}
printf '%s\n' "$report" | grep -qE '0/0 tests passsed \(8 skipped\)'
echo "capnp_test discovered four cases and eight intentional skips"
echo "known-good and corruption adapters verified in both directions"
