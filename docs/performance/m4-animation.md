# M4: animation decoder performance

Measured on an Apple M5 with Swift 6.4.2, on one thread, in a release build. The reference is libwebp 1.6.0's `WebPAnimDecoder` in straight RGBA mode, through `Tools/Oracle/anim-oracle.c`, on the same machine and in the same run. Both decoders produce the same pixels for every frame.

## Decoding speed

`webp-tools animation-speed` decodes every frame into one reused RGBA buffer with `nextFrame(into:bytesPerRow:)` and reports the best of seven runs. Speed counts the canvas pixels of every frame.

| Animation | Frames | swift-raster-webp | libwebp | Ratio |
|---|---:|---:|---:|---:|
| 512 × 512 pan across a photo, `img2webp -lossy -q 75 -m 4` | 30 | 124 Mpx/s | 168 Mpx/s | 74% |
| The same pan, `img2webp -lossless` | 30 | 64 Mpx/s | 70 Mpx/s | 92% |
| 400 × 300 photo with a translucent moving sprite, `img2webp -mixed` | 40 | 1037 Mpx/s | 1266 Mpx/s | 82% |

The frames are crops of `bryce.webp` from the libwebp test corpus. The milestone target was 50% of libwebp. Decoding the frames dominates, so the ratios are close to those of still images. In the sprite animation, where the encoder stores only a small rectangle per frame, writing the canvas to the output takes about 14 µs per frame.

Still images decode as fast as before the animation work: 104 Mpx/s at `-q 75` and 68–69 Mpx/s lossless, against 104–105 and 69 Mpx/s on `main`.

## Memory

The decoder keeps one canvas of four bytes per pixel. A frame that covers whole canvas rows and replaces them, such as a key frame, is decoded straight onto the canvas. Other frames are decoded into a work buffer that grows to the largest such frame and is then reused.

| Animation | Extra peak memory |
|---|---:|
| 512 × 512 pan, lossy | 3.6 MB |
| 512 × 512 pan, lossless | 3.7 MB |
| 400 × 300 sprite | 1.5 MB |

The extra memory is the peak memory footprint of a program that decodes every frame into its own 1 MB (512 × 512) or 0.5 MB (400 × 300) output buffer, minus that of the same program when it only reads the file. Apart from the output buffer, it holds the canvas, the work buffer and the decoders' own row buffers.

## Binary size

The program that decodes one image, described in [M3](m3-vp8-decoder.md), now also contains the animation compositor, because `WebPDecoder` decodes the first frame of an animation.

| Platform | Code (`.text`) | Stripped program |
|---|---:|---:|
| macOS, arm64 | +23.6 KB | +37 KB |
| Linux, aarch64, static | +22 KB | +68 KB, to 268 KB |

On Linux, the rest of the growth is about 13 KB of exported symbol names, 8 KB of unwind tables, and padding: the linker aligns segments to 64 KB on aarch64, so the file size grows in large steps.
