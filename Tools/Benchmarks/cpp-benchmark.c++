#include <capnp/message.h>
#include <capnp/serialize.h>
#include <capnp/blob.h>
#include "benchmark.capnp.h"
#include <chrono>
#include <cstdint>
#include <iostream>

using Clock = std::chrono::steady_clock;

template <typename Body>
void report(const char* name, uint64_t iterations, Body body) {
  auto start = Clock::now();
  auto checksum = body();
  auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - start).count();
  std::cout << "{\"implementation\":\"capnproto-c++\",\"benchmark\":\"" << name
            << "\",\"iterations\":" << iterations << ",\"nanoseconds\":" << elapsed
            << ",\"checksum\":" << checksum << "}\n";
}

int main(int argc, char** argv) {
  uint64_t iterations = argc > 1 ? std::stoull(argv[1]) : 10000;
  capnp::MallocMessageBuilder source;
  auto root = source.initRoot<Sample>();
  root.setValue(42);
  uint8_t payload[256];
  for (auto& byte: payload) byte = 7;
  root.setPayload(kj::arrayPtr(payload, 256));
  auto words = capnp::messageToFlatArray(source);

  report("decode", iterations, [&] {
    uint64_t sum = 0;
    for (uint64_t i = 0; i < iterations; ++i) {
      capnp::FlatArrayMessageReader reader(words.asPtr());
      sum += reader.getRoot<Sample>().getValue();
    }
    return sum;
  });
  report("traversal", iterations, [&] {
    uint64_t sum = 0;
    for (uint64_t i = 0; i < iterations; ++i) {
      capnp::FlatArrayMessageReader reader(words.asPtr());
      for (auto byte: reader.getRoot<Sample>().getPayload()) sum += byte;
    }
    return sum;
  });
  report("build", iterations, [&] {
    uint64_t sum = 0;
    for (uint64_t i = 0; i < iterations; ++i) {
      capnp::MallocMessageBuilder message;
      auto value = message.initRoot<Sample>();
      value.setValue(i);
      value.setPayload(kj::arrayPtr(payload, 256));
      sum += capnp::messageToFlatArray(message).size();
    }
    return sum;
  });
  report("serialize", iterations, [&] {
    uint64_t sum = 0;
    for (uint64_t i = 0; i < iterations; ++i) sum += capnp::messageToFlatArray(source).size();
    return sum;
  });
}
