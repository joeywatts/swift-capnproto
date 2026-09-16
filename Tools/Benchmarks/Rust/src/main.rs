use capnp::{message, serialize};
use std::time::Instant;

pub mod benchmark_capnp {
    include!(concat!(env!("OUT_DIR"), "/benchmark_capnp.rs"));
}

fn report(name: &str, iterations: u64, body: impl FnOnce() -> u64) {
    let start = Instant::now();
    let checksum = body();
    println!(
        "{{\"implementation\":\"capnproto-rust\",\"benchmark\":\"{}\",\"iterations\":{},\"nanoseconds\":{},\"checksum\":{}}}",
        name,
        iterations,
        start.elapsed().as_nanos(),
        checksum
    );
}

fn main() {
    let iterations = std::env::args()
        .nth(1)
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(10_000);
    let mut source = message::Builder::new_default();
    {
        let mut root = source.init_root::<benchmark_capnp::sample::Builder<'_>>();
        root.set_value(42);
        root.set_payload(&[7; 256]);
    }
    let words = serialize::write_message_to_words(&source);

    report("decode", iterations, || {
        let mut sum = 0;
        for _ in 0..iterations {
            let mut slice = words.as_slice();
            let reader = serialize::read_message_from_flat_slice(
                &mut slice,
                message::ReaderOptions::new(),
            )
            .unwrap();
            sum += reader
                .get_root::<benchmark_capnp::sample::Reader<'_>>()
                .unwrap()
                .get_value();
        }
        sum
    });
    report("traversal", iterations, || {
        let mut sum = 0;
        for _ in 0..iterations {
            let mut slice = words.as_slice();
            let reader = serialize::read_message_from_flat_slice(
                &mut slice,
                message::ReaderOptions::new(),
            )
            .unwrap();
            sum += reader
                .get_root::<benchmark_capnp::sample::Reader<'_>>()
                .unwrap()
                .get_payload()
                .unwrap()
                .iter()
                .map(|byte| *byte as u64)
                .sum::<u64>();
        }
        sum
    });
    report("build", iterations, || {
        let mut sum = 0;
        for index in 0..iterations {
            let mut value = message::Builder::new_default();
            let mut root = value.init_root::<benchmark_capnp::sample::Builder<'_>>();
            root.set_value(index);
            root.set_payload(&[7; 256]);
            sum += serialize::write_message_to_words(&value).len() as u64;
        }
        sum
    });
    report("serialize", iterations, || {
        let mut sum = 0;
        for _ in 0..iterations {
            sum += serialize::write_message_to_words(&source).len() as u64;
        }
        sum
    });
}
