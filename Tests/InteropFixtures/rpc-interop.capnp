@0xdadadadadadadada;

interface Echo @0xeeeeeeeeeeeeeeee {
  increment @0 (value :UInt32) -> (value :UInt32);
}

interface Bootstrap @0xbbbbbbbbbbbbbbbb {
  getEcho @0 () -> (echo :Echo);
}
