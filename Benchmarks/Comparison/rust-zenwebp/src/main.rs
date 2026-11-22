// zenwebp decodes straight into RGBA.
fn decode_rgba(bytes: &[u8]) -> Result<Vec<u8>, String> {
    zenwebp::oneshot::decode_rgba(bytes).map(|(pixels, _, _)| pixels).map_err(|e| format!("{e:?}"))
}

fn main() {
    bench_support::main(
        |bytes| {
            let (pixels, width, height) = zenwebp::oneshot::decode_rgba(bytes).map_err(|e| format!("{e:?}"))?;
            std::hint::black_box(pixels);
            Ok((width, height))
        },
        decode_rgba,
    );
}
