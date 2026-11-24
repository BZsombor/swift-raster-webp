# ADR 0006: Composite animations like libwebp's WebPAnimDecoder

**Status:** Accepted

## Context

RFC 9649 section 2.7 defines how the frames of an animation are placed on a canvas, but it leaves several details open or only recommends them:

- The background color of the `ANIM` chunk is "a hint", and viewers are not required to use it.
- Alpha-blending "SHOULD be done in linear color space", while common viewers blend the stored sRGB values.
- The blending formula is given with real numbers, without a rounding rule.
- The prose and the pseudocode disagree on whether the loop count includes the first play.
- The specification says nothing about a mismatch between the `VP8X` flags and the chunks, and it lets readers ignore repeated metadata chunks.

For testing, bit-exact output is as valuable here as for lossy images ([ADR 0004](0004-yuv-to-rgb-conversion.md)). [ADR 0003](0003-implementation-sources.md) allows matching another implementation's observable output where a specification leaves behavior open, as long as the code and constants are our own. The reference is libwebp's `WebPAnimDecoder`, observed through `Tools/Oracle/anim-oracle.c`. The `anim_dump` tool is not used as the reference, because it clears the color of fully transparent pixels after decoding.

## Decision

**Canvas.** The canvas starts transparent black, `(0, 0, 0, 0)`, and disposing a frame to the background fills its rectangle with transparent black. The background color of the file is reported in `WebPAnimationInfo` and is not used for compositing. `WebPAnimDecoder` behaves the same way.

**Color space.** Frames are blended in the stored sRGB values, not in linear light.

**Blending.** The canvas holds straight (not premultiplied) alpha. A frame that blends is combined with the canvas, pixel by pixel, in integer arithmetic, where `s` is the frame and `d` is the canvas:

| Case | Result |
|---|---|
| `s.a = 255` | `s` |
| `s.a = 0` | `d` |
| Otherwise | `f = (d.a · (256 − s.a)) >> 8`, `a = s.a + f`, `c = ((s.c · s.a + d.c · f) · ⌊2²⁴ / a⌋) >> 24` for each color channel `c` |

This is the formula of the RFC, with the factor `1 − s.a / 255` approximated in 8-bit fixed point and the division by the result alpha done with a 24-bit reciprocal. `Scripts/fit-animation-blending.py` checks it against `WebPAnimDecoder`: in each round it blends all 65,536 pairs of source and destination alpha with random colors. With 16 rounds, all 1,048,576 pixels agree, with libwebp 1.6.0.

**Where the canvas is known to be transparent, frames replace it.** Blending over a transparent pixel with the formula above does not always give the source pixel back, and `WebPAnimDecoder` avoids blending in two cases. A blending frame replaces the pixels it covers, as if it did not blend:

- when the canvas is entirely transparent before the frame: for the first frame, and for a frame after one that is disposed to the background and either covers the whole canvas or was itself drawn on an entirely transparent canvas;
- inside the rectangle that the previous frame disposed to the background.

A model with exactly these two rules agreed with `WebPAnimDecoder` on 123 random animations, and removing either rule made some of them disagree. Clearing the whole canvas before such a frame, which libwebp's notion of a key frame suggests, makes no visible difference, so the decoder does not do it.

**Premultiplied output.** Compositing always uses the straight canvas, and premultiplied output is the premultiplied canvas. `WebPAnimDecoder` blends premultiplied values in its premultiplied mode, which can differ in the last bit. One compositing path keeps the code small and gives a single reference.

**Timing.** Each frame reports its duration and the time at which it starts, the sum of the durations before it. `WebPAnimDecoder` reports the time at which a frame ends instead. Durations are reported as stored, including 0. The loop count is reported as stored, with 0 meaning forever, and the caller decides how to repeat.

**Metadata.** The presence of an `ICCP`, `EXIF` or `XMP ` chunk decides whether the file has that metadata, and the `VP8X` flags are not consulted. When a type appears more than once, the first chunk is used. An `ICCP` chunk after the image data is accepted, because the pixels and the profile are still unambiguous.

## Consequences

- Every animation can be tested bit for bit against `WebPAnimDecoder` in straight-alpha mode.
- Premultiplied animation output is tested against the premultiplied oracle output in straight mode, not against libwebp's premultiplied mode.
- Color-managed compositing, in linear light or with the ICC profile, is left to applications such as raster.
- A file whose metadata flags disagree with its chunks still decodes, while libwebp's `webpmux` rejects it.
