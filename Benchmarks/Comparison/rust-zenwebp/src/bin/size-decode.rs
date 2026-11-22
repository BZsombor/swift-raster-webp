// The same program as size-empty, plus decoding, so the size difference is the decoder.
fn main() {
    let argument = std::env::args().nth(1).unwrap_or_default();
    println!("{}", argument.len());
    if let Ok((_, width, _)) = zenwebp::oneshot::decode_rgba(argument.as_bytes()) {
        println!("{width}");
    }
}
