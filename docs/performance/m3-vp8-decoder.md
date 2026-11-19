# M3: lossy decoder performance

Measured on an Apple M5 with Swift 6.4.2, on one thread, in a release build. The reference is `dwebp` from libwebp 1.6.0 on the same machine and in the same run.

## Decoding speed

| Image | Size | swift-raster-webp | libwebp | Ratio |
|---|---:|---:|---:|---:|
| Natural photo, `cwebp -q 75` | 24.1 Mpx | 104 Mpx/s | 147 Mpx/s | 71% |
| Natural photo, `cwebp -q 90` | 24.1 Mpx | 75 Mpx/s | 97 Mpx/s | 78% |

The milestone target was 50% of libwebp. All memory access is bounds-checked, and the vector code uses only the standard library's portable SIMD types, without platform intrinsics.

## libwebp without its SIMD code

To see how much of libwebp's speed comes from its hand-written SIMD code, `dwebp` was also built from the libwebp sources with NEON disabled. Its timings below come from `dwebp -v`, so they differ slightly from the table above.

| Image | libwebp with NEON | libwebp without NEON |
|---|---:|---:|
| `cwebp -q 75` | 0.147 s | 0.241 s (61% of the speed) |
| `cwebp -q 90` | 0.217 s | 0.293 s (74% of the speed) |

## Optimization notes

Each step was kept only when it stayed bit-exact with libwebp on the whole test corpus.

| Change | Speed at `-q 75` |
|---|---|
| Starting point: scalar code | About 65 Mpx/s |
| Color conversion 8 pixels at a time with `SIMD8<Int32>` | 72 Mpx/s |
| Loop filter on 16 segments at once, horizontal edges | 77 Mpx/s |
| Vertical edges, transposed lane by lane | 65 Mpx/s, rejected |
| Vertical edges, transposed with `evenHalf` and `oddHalf` shuffles | 81 Mpx/s |
| Lane masks as integer vectors instead of `SIMDMask` and `replacing(with:where:)` | 90 Mpx/s |
| Inverse DCT on four lanes, and vector copies of reconstructed rows | 98 Mpx/s |
| 16x16 and 8x8 prediction one row vector at a time | No measurable change, kept for simplicity |
| Token loop: probabilities arranged by coefficient position, and a separate loop for zero runs | 104 Mpx/s |

Two lessons about the standard library's SIMD types apply to the rest of the project:

- `SIMDMask` with `replacing(with:where:)` compiles to one branch per lane. Integer masks of all ones or all zeros with bitwise selects compile to single vector instructions.
- Generic code over `SIMD` compiles to one lane at a time. Vector helpers are written for concrete types, such as `SIMD16<Int16>`.

## Reproducing the measurements

```bash
swift run -c release --package-path Tools webp-tools speed image.webp
```
