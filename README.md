# swift-raster-webp

WebP support written entirely in Swift, with no C dependencies and no Foundation requirement.

This package is the first building block of **raster**, a planned cross-platform image library for Swift.

> [!IMPORTANT]
> **Early development.** The package can read WebP file properties. It cannot decode or encode pixels yet.

## Usage

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/BZsombor/swift-raster-webp.git", from: "0.1.0")
```

```swift
.product(name: "RasterWebP", package: "swift-raster-webp")
```

Read the properties of a complete WebP file:

```swift
import RasterWebP

let info = try WebPImageInfo(parsing: bytes)

print(info.width, info.height)
print(info.compression)      // .lossy, .lossless or .mixed
print(info.hasAlpha)
print(info.animation?.frameCount ?? 1)
```

## Roadmap

- [x] RIFF container parsing and image properties
- [ ] Lossless decoding (VP8L)
- [ ] Lossy decoding (VP8) with alpha
- [ ] Animation decoding, and ICC, EXIF and XMP access
- [ ] Lossless encoding, then the 1.0 release
- [ ] Lossy and animation encoding

## Requirements

- Swift 6.3 or later
- macOS 13, iOS 16, tvOS 16, watchOS 9 or visionOS 1 on Apple platforms
- Linux, Windows, Android and WebAssembly are supported targets

## Implementation

The code is written from the WebP specifications, [RFC 9649](https://www.rfc-editor.org/rfc/rfc9649.html) and [RFC 6386](https://www.rfc-editor.org/rfc/rfc6386.html). Libraries in other languages serve only as references for comparing approaches and verifying results. No code is copied or ported from them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please report security issues as described in [SECURITY.md](SECURITY.md).

## License

Licensed under the [Apache License 2.0](LICENSE).
