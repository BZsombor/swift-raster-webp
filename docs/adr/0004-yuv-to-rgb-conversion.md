# ADR 0004: Convert YUV to RGB like dwebp, from BT.601

**Status:** Accepted

## Context

A VP8 frame stores a luma plane and two chroma planes at half resolution. Neither RFC 6386 nor RFC 9649 says how these become RGB pixels, so every decoder chooses its own conversion and chroma upsampling, and the results differ in the last bit.

For testing, bit-exact output is valuable: if our pixels equal `dwebp`'s, every lossy file in the corpus and every randomly encoded file can be checked exactly. [ADR 0003](0003-implementation-sources.md) allows matching another implementation's observable output where a specification leaves behavior open, as long as the code and constants are our own.

## Decision

Lossy images are converted to match `dwebp`'s default output exactly. The method is derived from public standards and from `dwebp`'s output, not from its code.

**Chroma upsampling.** Each output pixel blends the four nearest chroma samples bilinearly: weight 9 for the nearest one, 3 for its horizontal and vertical neighbors and 1 for the diagonal one, with rounding: `(9a + 3b + 3c + d + 8) >> 4`. At the image edges the outermost samples repeat.

**Conversion.** The factors come from ITU-R BT.601 with `Kr = 0.299` and `Kb = 0.114`, for limited-range input: luma from 16 to 235 and chroma from 16 to 240 around 128.

| Factor | Formula | Value | × 2^14 |
|---|---|---:|---:|
| Luma | 255 / 219 | 1.164384 | 19077 |
| Red from V | 2 (1 − Kr) · 255 / 224 | 1.596027 | 26149 |
| Green from U | 2 (1 − Kb) Kb / Kg · 255 / 224 | 0.391762 | 6419 |
| Green from V | 2 (1 − Kr) Kr / Kg · 255 / 224 | 0.812968 | 13320 |
| Blue from U | 2 (1 − Kb) · 255 / 224 | 2.017232 | 33050 |

Each channel is computed in fixed point as `((y · 19077) >> 8) ± ((c · factor) >> 8) + offset`, shifted right by 6 and clamped to 0…255. The offset combines the −16 and −128 centers of the input ranges with a rounding term of 32:

| Channel | Predicted by the centers and rounding | Offset used |
|---|---:|---:|
| Red | −14234.8 | −14234 |
| Green | 8709.2 | 8708 |
| Blue | −17685.3 | −17685 |

The exact offsets were fitted with `Scripts/fit-yuv-offsets.py`. For every pixel of the test images it computes the range of offsets that reproduces `dwebp`'s 8-bit output, and each channel has exactly one offset that agrees with all pixels.

## Consequences

- Every lossy file can be tested bit for bit. The conformance tests compare both the YUV planes and the RGB pixels with `dwebp`, so a difference in the VP8 decoder and a difference in the conversion show up separately.
- The output depends on one particular choice of rounding. A faster conversion with different rounding could come later as an option, but not as the default.
- The constants are derived from BT.601 and from observed output, so a reviewer can recompute every one of them.
