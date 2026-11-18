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

Parsing treats every input as untrusted. Invalid data produces a ``WebPError``, and parsing never copies the input.

## Topics

### Reading image properties

- ``WebPImageInfo``
- ``WebPCompression``
- ``WebPAnimationInfo``
- ``WebPBackgroundColor``

### Handling failures

- ``WebPError``
