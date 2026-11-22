// The same program as size-empty, plus decoding, so the size difference is the decoder.
fn main() {
    let argument = std::env::args().nth(1).unwrap_or_default();
    println!("{}", argument.len());
    if let Ok(mut decoder) = image_webp::WebPDecoder::new(std::io::Cursor::new(argument.as_bytes())) {
        let mut pixels = vec![0u8; decoder.output_buffer_size().unwrap_or(0)];
        if decoder.read_image(&mut pixels).is_ok() {
            println!("{}", decoder.dimensions().0);
        }
    }
}
