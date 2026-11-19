# M2: lossless decoder performance

Measured on an Apple M5 with Swift 6.4.2, on one thread, in a release build. The reference is `dwebp` from libwebp 1.6.0 on the same machine and in the same run.

## Decoding speed

| Image | Size | swift-raster-webp | libwebp | Ratio |
|---|---:|---:|---:|---:|
| Natural photo, `cwebp -lossless -z 6` | 24.1 Mpx | 66 Mpx/s | 70 Mpx/s | 94% |
| `lossless_big_random_alpha.webp` | libwebp test corpus | 65 Mpx/s | 72 Mpx/s | 90% |

The milestone target was 50% of libwebp, and the 1.0 target is 70%. All pixel access is bounds-checked, and the decoder uses no SIMD intrinsics.

## Size and memory

| Metric | Result | Target |
|---|---:|---:|
| Binary size added by the decoder (Linux aarch64, static, stripped) | 135 KB | at most 400 KB |
| Peak memory footprint of the measuring tool for the 24.1 Mpx image | 156 MB | |
| Input file plus decoded RGBA pixels of that image | 123 MB | |

## Optimization notes

| Change | Effect on the natural photo |
|---|---|
| One loop per prediction mode with scalar channel arithmetic | From about 60 to about 70 Mpx/s |
| `SIMD4<Int32>` lanes for the select and clamp predictors | No gain, and slower on noisy images, so it was rejected |

## Reproducing the measurements

```bash
swift run -c release --package-path Tools webp-tools speed image.webp
```
