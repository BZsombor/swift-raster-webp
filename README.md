# swift-raster-webp

WebP support written entirely in Swift, with no C dependencies and no Foundation requirement.

This package is the first building block of **raster**, a planned cross-platform image library for Swift.

> [!IMPORTANT]
> **Early development.** The package decodes lossless WebP images. Lossy images and animations are not supported yet.

## Usage

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/BZsombor/swift-raster-webp.git", branch: "main")
```

```swift
.product(name: "RasterWebP", package: "swift-raster-webp")
```

Decode an image:

```swift
import RasterWebP

let image = try WebPDecoder.decode(bytes)

print(image.width, image.height)
print(image.pixels.count)    // RGBA, four bytes per pixel
```

Choose the output format and limit the resources that untrusted files can use:

```swift
var options = WebPDecodingOptions()
options.pixelFormat = .bgra8
options.alphaMode = .premultiplied
options.limits.maximumPixelCount = 50_000_000

let image = try WebPDecoder.decode(bytes, options: options)
```

Read the properties of a file without decoding it:

```swift
let info = try WebPImageInfo(parsing: bytes)

print(info.width, info.height, info.compression, info.hasAlpha)
```

## Roadmap

- [x] RIFF container parsing and image properties
- [x] Lossless decoding (VP8L)
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
