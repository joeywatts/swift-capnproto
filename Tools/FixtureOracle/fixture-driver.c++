#include "fixture.capnp.h"

#include <capnp/message.h>
#include <capnp/serialize-packed.h>
#include <capnp/serialize.h>
#include <kj/array.h>

#include <fcntl.h>
#include <unistd.h>

#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

using Fixture = SwiftCapnpFixtures::Fixture;

void populateStandard(Fixture::Builder root) {
  root.setName("standard");
  root.setLabel("union");
  auto details = root.getDetails();
  details.setEnabled(true);
  details.setCount(7);
  auto nested = root.initNested(2);
  auto first = nested.init(0, 2);
  first.set(0, 1);
  first.set(1, 2);
  auto second = nested.init(1, 3);
  second.set(0, 3);
  second.set(1, 4);
  second.set(2, 5);
}

void populate(capnp::MessageBuilder& message, const std::string& fixture) {
  auto root = message.initRoot<Fixture>();
  if (fixture == "flat" || fixture == "stream" || fixture == "packed") {
    populateStandard(root);
  } else if (fixture == "multi-segment") {
    populateStandard(root);
    root.setName("multi-segment-padding-for-a-second-allocation");
  } else if (fixture == "defaults") {
    // Leave every field at its wire default.
  } else if (fixture == "union") {
    root.setName("union");
    root.setNumber(42);
  } else if (fixture == "group") {
    root.setName("group");
    root.getDetails().setEnabled(true);
    root.getDetails().setCount(99);
  } else if (fixture == "nested-list") {
    root.setName("nested-list");
    auto nested = root.initNested(2);
    auto first = nested.init(0, 1);
    first.set(0, 10);
    auto second = nested.init(1, 2);
    second.set(0, 20);
    second.set(1, 30);
  } else {
    throw std::runtime_error("unknown fixture: " + fixture);
  }
}

int openOutput(const std::string& path) {
  int fd = open(path.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (fd < 0) throw std::runtime_error("could not open output: " + path);
  return fd;
}

void generate(const std::string& fixture, const std::string& path) {
  capnp::MallocMessageBuilder message(
      fixture == "multi-segment" ? 1 : 1024,
      fixture == "multi-segment" ? capnp::AllocationStrategy::FIXED_SIZE
                                  : capnp::AllocationStrategy::GROW_HEURISTICALLY);
  populate(message, fixture);

  if (fixture == "flat") {
    auto segments = message.getSegmentsForOutput();
    if (segments.size() != 1) throw std::runtime_error("flat fixture has multiple segments");
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(segments[0].begin()), segments[0].asBytes().size());
    if (!output) throw std::runtime_error("could not write flat fixture");
    return;
  }

  int fd = openOutput(path);
  if (fixture == "packed") {
    capnp::writePackedMessageToFd(fd, message);
  } else {
    capnp::writeMessageToFd(fd, message);
  }
  close(fd);
}

void printJson(Fixture::Reader root) {
  auto defaults = root.getDefaults();
  auto details = root.getDetails();
  std::cout << "{\"name\":\"" << root.getName().cStr() << "\","
            << "\"boolDefault\":" << (defaults.getBoolValue() ? "true" : "false") << ","
            << "\"intDefault\":" << defaults.getIntValue() << ",\"choice\":{";
  if (root.which() == Fixture::LABEL) {
    std::cout << "\"label\":\"" << root.getLabel().cStr() << "\"";
  } else {
    std::cout << "\"number\":" << root.getNumber();
  }
  std::cout << "},\"details\":{\"enabled\":"
            << (details.getEnabled() ? "true" : "false") << ",\"count\":"
            << details.getCount() << "},\"nested\":[";
  auto outer = root.getNested();
  for (unsigned i = 0; i < outer.size(); ++i) {
    if (i != 0) std::cout << ',';
    std::cout << '[';
    auto inner = outer[i];
    for (unsigned j = 0; j < inner.size(); ++j) {
      if (j != 0) std::cout << ',';
      std::cout << inner[j];
    }
    std::cout << ']';
  }
  std::cout << "]}\n";
}

void decode(const std::string& fixture, const std::string& path) {
  if (fixture == "flat") {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    auto size = input.tellg();
    if (size < 0 || size % sizeof(capnp::word) != 0) {
      throw std::runtime_error("flat fixture is not word aligned");
    }
    input.seekg(0);
    auto words = kj::heapArray<capnp::word>(static_cast<size_t>(size) / sizeof(capnp::word));
    input.read(reinterpret_cast<char*>(words.begin()), size);
    kj::ArrayPtr<const capnp::word> segment = words.asPtr();
    kj::ArrayPtr<const kj::ArrayPtr<const capnp::word>> segments(&segment, 1);
    capnp::SegmentArrayMessageReader reader(segments);
    printJson(reader.getRoot<Fixture>());
    return;
  }

  int fd = open(path.c_str(), O_RDONLY);
  if (fd < 0) throw std::runtime_error("could not open input: " + path);
  if (fixture == "packed") {
    capnp::PackedFdMessageReader reader(fd);
    printJson(reader.getRoot<Fixture>());
  } else {
    capnp::StreamFdMessageReader reader(fd);
    printJson(reader.getRoot<Fixture>());
  }
  close(fd);
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 4) {
      std::cerr << "usage: fixture-driver generate|decode FIXTURE PATH\n";
      return 64;
    }
    std::string operation = argv[1];
    if (operation == "generate") {
      generate(argv[2], argv[3]);
    } else if (operation == "decode") {
      decode(argv[2], argv[3]);
    } else {
      return 64;
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
