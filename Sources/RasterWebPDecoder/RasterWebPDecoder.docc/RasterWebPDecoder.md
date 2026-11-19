# ``RasterWebPDecoder``

Decode WebP images in pure Swift, without C dependencies or Foundation.

## Overview

Decode a complete file into RGBA pixels:

```swift
import RasterWebP

let image = try WebPDecoder.decode(bytes)
```

Every input is treated as untrusted. Invalid data produces a `WebPError`, and ``WebPDecodingLimits`` restricts the resources that a file can use.

This version decodes lossless images. Lossy and animated files produce an error whose kind is `unsupportedFeature`.

## Topics

### Decoding

- ``WebPDecoder``
- ``WebPImage``

### Configuring the output

- ``WebPDecodingOptions``
- ``WebPPixelFormat``
- ``WebPAlphaMode``
- ``WebPDecodingLimits``
