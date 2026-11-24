# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Animation decoding with `WebPAnimationDecoder`, frame by frame, bit-exact with libwebp's `WebPAnimDecoder`, also into caller-provided memory.
- `WebPFrameInfo` for reading the position, size, timing, blending and disposal of every frame without decoding.
- `WebPMetadata` for reading the ICC profile and the EXIF and XMP metadata.
- `maximumFrameCount` and `maximumAnimationPixelCount` limits for untrusted animations.

### Changed

- `WebPDecoder` decodes the first frame of an animated file instead of reporting an unsupported feature.

## [0.3.0] - 2026-11-21

### Added

- Lossy (VP8) image decoding, bit-exact with libwebp's `dwebp`, including segments, both loop filters and multiple token partitions.
- Transparency in lossy images, from raw and lossless-compressed `ALPH` chunks with every filter.

## [0.2.0] - 2026-11-20

### Added

- Lossless (VP8L) image decoding with `WebPDecoder`.
- RGBA, BGRA, RGB and BGR output, with straight or premultiplied alpha.
- Decoding into caller-provided memory.
- Pixel and memory limits for untrusted files.

## [0.1.0] - 2026-11-18

### Added

- RIFF container parsing.
- `WebPImageInfo` for reading image properties without decoding pixels.

[Unreleased]: https://github.com/BZsombor/swift-raster-webp/compare/0.3.0...HEAD
[0.3.0]: https://github.com/BZsombor/swift-raster-webp/releases/tag/0.3.0
[0.2.0]: https://github.com/BZsombor/swift-raster-webp/releases/tag/0.2.0
[0.1.0]: https://github.com/BZsombor/swift-raster-webp/releases/tag/0.1.0
