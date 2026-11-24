# ``RasterWebPCore``

Read WebP files in pure Swift, without C dependencies or Foundation.

## Overview

Import `RasterWebP` and read the properties of a complete WebP file without decoding its pixels:

```swift
import RasterWebP

let info = try WebPImageInfo(parsing: bytes)

print(info.width, info.height)
print(info.compression)
print(info.hasAlpha)
```

Read the color profile and metadata, which are returned without interpretation:

```swift
let metadata = try WebPMetadata(parsing: bytes)

if let profile = metadata.iccProfile {
    print("ICC profile of \(profile.count) bytes")
}
```

Parsing treats every input as untrusted. Invalid data produces a ``WebPError``, and parsing never copies the input, except for the metadata that ``WebPMetadata`` returns.

## Topics

### Reading image properties

- ``WebPImageInfo``
- ``WebPCompression``
- ``WebPAnimationInfo``
- ``WebPBackgroundColor``

### Reading animation frames

- ``WebPFrameInfo``
- ``WebPFrameBlending``
- ``WebPFrameDisposal``

### Reading metadata

- ``WebPMetadata``

### Handling failures

- ``WebPError``
