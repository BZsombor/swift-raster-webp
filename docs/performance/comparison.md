# Decoding speed compared with other WebP decoders

Measured on 2026-11-20 on an Apple M5, on one thread, with release builds:

- **swift-raster-webp** at commit `1b68f0e`, built with Swift 6.4.2.
- **[image-webp](https://crates.io/crates/image-webp) 0.2.4**, the pure Rust decoder of the `image` crate, built with Rust 1.94 using `lto = "fat"` and `codegen-units = 1`.
- **[libwebp](https://chromium.googlesource.com/webm/libwebp) 1.6.0**, Google's C library with hand-written NEON code, timed by `dwebp -v`.

| Image (24.1 Mpx) | swift-raster-webp | image-webp | libwebp |
|---|---:|---:|---:|
| Lossy, `cwebp -q 75` | **106 Mpx/s** | 74 Mpx/s | 149 Mpx/s |
| Lossy, `cwebp -q 90` | **78 Mpx/s** | 58 Mpx/s | 99 Mpx/s |
| Lossless, `cwebp -lossless -z 6` | **70 Mpx/s** | 57 Mpx/s | 74 Mpx/s |

Relative to the others, swift-raster-webp decodes:

| Image | Compared with image-webp | Share of libwebp's speed |
|---|---:|---:|
| Lossy, `-q 75` | 1.43× as fast | 71% |
| Lossy, `-q 90` | 1.34× as fast | 79% |
| Lossless | 1.23× as fast | 95% |

## How it was measured

- **The image** is `bryce.webp` from the libwebp test corpus, an 11158 × 2156 photo, decoded and encoded again with `cwebp` at the settings in the table.
- **Each number** is the best of 7 decodes from memory, including the allocation of the output, so file reading and writing are not counted.
- **All three decoders produce identical pixels.** Both swift-raster-webp and image-webp match `dwebp` bit for bit on these images.
- **The output formats differ slightly.** swift-raster-webp and libwebp write RGBA. image-webp writes RGB for opaque images, which is less work.
- **No platform intrinsics.** swift-raster-webp uses the Swift standard library's portable SIMD types, and its memory accesses are bounds-checked. image-webp is scalar, safe Rust.

Speeds vary by a few percent between runs. Two consecutive runs of the script agreed within 3%.

## Reproducing the measurements

The script needs `swift`, `cargo`, `cwebp` and `dwebp`. It builds the Rust measuring program in a temporary directory, with its own cargo home, and removes everything at the end.

```bash
Scripts/fetch-corpus.sh
Scripts/compare-decoders.sh
```

The detailed measurements of each decoder are in [the lossless](m2-vp8l-decoder.md) and [the lossy](m3-vp8-decoder.md) performance notes.
