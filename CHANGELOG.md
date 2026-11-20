# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/BZsombor/swift-raster-webp/compare/0.2.0...HEAD
[0.2.0]: https://github.com/BZsombor/swift-raster-webp/releases/tag/0.2.0
[0.1.0]: https://github.com/BZsombor/swift-raster-webp/releases/tag/0.1.0
