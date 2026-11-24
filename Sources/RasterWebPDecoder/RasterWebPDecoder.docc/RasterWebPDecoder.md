# ``RasterWebPDecoder``

Decode WebP images in pure Swift, without C dependencies or Foundation.

## Overview

Decode a complete file into RGBA pixels:

```swift
import RasterWebP

let image = try WebPDecoder.decode(bytes)
```

Decode every frame of an animation:

```swift
var decoder = try WebPAnimationDecoder(bytes)
while let frame = try decoder.nextFrame() {
    show(frame.image, for: frame.duration)
}
```

The decoder handles lossless (VP8L) and lossy (VP8) images, transparency and animations. For an animation, ``WebPDecoder`` returns the first frame.

Every input is treated as untrusted. Invalid data produces a `WebPError`, and ``WebPDecodingLimits`` restricts the resources that a file can use.

## Topics

### Decoding

- ``WebPDecoder``
- ``WebPImage``

### Decoding animations

- ``WebPAnimationDecoder``
- ``WebPAnimationFrame``
- ``WebPFrameTiming``

### Configuring the output

- ``WebPDecodingOptions``
- ``WebPPixelFormat``
- ``WebPAlphaMode``
- ``WebPDecodingLimits``
