//! The command-line contract of the comparison's measuring programs, shared by the Rust ones.
//! It matches Benchmarks/Comparison/swift/Sources/BenchSupport/Bench.swift.

use std::time::Instant;

type Decode = fn(&[u8]) -> Result<(u32, u32), String>;
type Rgba = fn(&[u8]) -> Result<Vec<u8>, String>;

/// Runs `speed`, `hash`, `decode` or `read`. `decode` produces the library's usual output,
/// converted to RGBA where it differs, and `rgba` produces straight RGBA for comparisons.
pub fn main(decode: Decode, rgba: Rgba) {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let name = |path: &str| path.rsplit('/').next().unwrap_or(path).to_string();
    let read = |path: &str| std::fs::read(path).unwrap_or_else(|error| fail(&error.to_string()));
    match arguments.first().map(String::as_str) {
        Some("speed") if arguments.len() >= 4 => {
            let warmup: usize = arguments[1].parse().unwrap_or(3);
            let runs: usize = arguments[2].parse().unwrap_or(20);
            for path in &arguments[3..] {
                let bytes = read(path);
                let mut size = (0, 0);
                for _ in 0..warmup {
                    size = decode(&bytes).unwrap_or_else(|error| fail(&error));
                }
                let mut times = Vec::with_capacity(runs);
                for _ in 0..runs {
                    let start = Instant::now();
                    size = decode(&bytes).unwrap_or_else(|error| fail(&error));
                    times.push(start.elapsed().as_secs_f64() * 1e3);
                }
                times.sort_by(|a, b| a.partial_cmp(b).unwrap());
                let median = if runs % 2 == 1 {
                    times[runs / 2]
                } else {
                    (times[runs / 2 - 1] + times[runs / 2]) / 2.0
                };
                println!(
                    "{{\"file\":\"{}\",\"width\":{},\"height\":{},\"median_ms\":{},\"best_ms\":{},\"runs\":{}}}",
                    name(path), size.0, size.1, median, times[0], runs
                );
            }
        }
        Some("hash") => {
            for path in &arguments[1..] {
                match std::fs::read(path).map_err(|error| error.to_string()).and_then(|bytes| rgba(&bytes)) {
                    Ok(pixels) => {
                        let hash = pixels
                            .iter()
                            .fold(0xcbf29ce484222325u64, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3));
                        println!("{}\t{hash:016x}", name(path));
                    }
                    Err(error) => println!("{}\tERROR {}", name(path), error.replace('\n', " ")),
                }
            }
        }
        Some("decode") if arguments.len() == 2 => {
            let size = decode(&read(&arguments[1])).unwrap_or_else(|error| fail(&error));
            println!("{}", size.0);
        }
        Some("read") if arguments.len() == 2 => println!("{}", read(&arguments[1]).len()),
        _ => fail("usage: speed|hash|decode|read"),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("error: {message}");
    std::process::exit(1)
}

/// Expands RGB pixels to RGBA with opaque alpha.
pub fn rgb_to_rgba(rgb: &[u8]) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(rgb.len() / 3 * 4);
    for pixel in rgb.chunks_exact(3) {
        rgba.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
    }
    rgba
}
