#include "rpc-interop.capnp.h"
#include <capnp/ez-rpc.h>
#include <kj/debug.h>
#include <kj/async-io.h>
#include <cstdlib>
#include <iostream>

class EchoImpl final: public Echo::Server {
public:
  explicit EchoImpl(kj::Own<kj::PromiseFulfiller<void>> done): done(kj::mv(done)) {}

  kj::Promise<void> increment(IncrementContext context) override {
    context.getResults().setValue(context.getParams().getValue() + 1);
    done->fulfill();
    return kj::READY_NOW;
  }

private:
  kj::Own<kj::PromiseFulfiller<void>> done;
};

int main(int argc, char** argv) {
  KJ_REQUIRE(argc >= 2, "usage: rpc-interop server|client [port]");
  std::string mode = argv[1];
  if (mode == "server") {
    auto paf = kj::newPromiseAndFulfiller<void>();
    capnp::EzRpcServer server(kj::heap<EchoImpl>(kj::mv(paf.fulfiller)), "127.0.0.1", 0);
    std::cout << server.getPort().wait(server.getWaitScope()) << std::endl;
    paf.promise.wait(server.getWaitScope());
    server.getIoProvider().getTimer().afterDelay(10 * kj::MILLISECONDS).wait(server.getWaitScope());
    return 0;
  }
  KJ_REQUIRE(mode == "client" && argc == 3, "client requires port");
  capnp::EzRpcClient client("127.0.0.1", static_cast<uint>(std::strtoul(argv[2], nullptr, 10)));
  auto echo = client.getMain<Echo>();
  auto request = echo.incrementRequest();
  request.setValue(41);
  std::cout << request.send().wait(client.getWaitScope()).getValue() << std::endl;
  return 0;
}
