// Measures image-webp the same way as `webp-tools speed`: the best of 7 decodes from memory,
// including the allocation of the output buffer.
use std::io::Cursor;
use std::time::Instant;

fn main() {
    for path in std::env::args().skip(1) {
        let bytes = std::fs::read(&path).expect("readable file");
        let mut best = f64::INFINITY;
        let mut megapixels = 0.0;
        for _ in 0..7 {
            let start = Instant::now();
            let mut decoder = image_webp::WebPDecoder::new(Cursor::new(&bytes)).expect("valid header");
            let mut pixels = vec![0u8; decoder.output_buffer_size().expect("known size")];
            decoder.read_image(&mut pixels).expect("valid image");
            best = best.min(start.elapsed().as_secs_f64());

            let (width, height) = decoder.dimensions();
            megapixels = (width as f64) * (height as f64) / 1e6;
            assert!(pixels.iter().any(|&value| value != 0));
        }
        let name = path.rsplit('/').next().unwrap_or(&path);
        println!("{name}: {:.0} Mpx/s", megapixels / best);
    }
}
