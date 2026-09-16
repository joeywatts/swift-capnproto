# Generated API guide

Generated schema namespaces contain `Reader` and `Builder` views. Readers retain
their message storage. Builders retain their arena. Unknown enum and union values
remain available as raw values, allowing newer senders to communicate safely
with older readers.

Compile schemas with `capnp-swift compile`, or attach `CapnProtoPlugin` to a
SwiftPM target. Generated capability namespaces provide `Client`, `Server`,
method descriptors, dispatch, and pipeline result views. A request method returns
a pipeline immediately; await `response()` only when the full result is needed.
