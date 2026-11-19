# Unsafe code audit

Every use of `unsafe` in the library is listed here with the invariant that makes it correct.

| Location | Operation | Invariant |
|---|---|---|
| `Sources/RasterWebPCore/Container/WebPImageInfo+Parsing.swift`, `init(parsing: [UInt8])` | Creates a `Span` from the array's buffer pointer. | The span is only used inside the closure, while the array keeps its storage alive. |
| `Sources/RasterWebPDecoder/API/WebPDecoder.swift`, `decode(_: Span<UInt8>, options:)` | Fills uninitialized array storage. | The storage is zero-initialized before use, and the initialized count never exceeds its capacity. |
| `Sources/RasterWebPDecoder/API/WebPDecoder.swift`, `decodeInPlace` | Rebinds byte storage to `UInt32`. | Callers pass memory aligned to four bytes that holds four bytes per pixel, and the rebound buffer is only used inside the closure. |
| `Sources/RasterWebPDecoder/Lossless/BitReader.swift`, `refill` | Loads eight unaligned bytes. | The load is bounds-checked, and `end - position >= 8` holds. `UInt64` accepts every bit pattern. |
| `Sources/RasterWebPDecoder/Lossy/BoolDecoder.swift`, `refill` | Loads eight unaligned bytes. | The load is bounds-checked and only runs while at least eight bytes remain. `UInt64` accepts every bit pattern. |
| `Sources/RasterWebPDecoder/Support/Span+Vectors.swift` | Loads and stores whole SIMD vectors in spans. | `RawSpan` and `MutableRawSpan` check the bounds. Loads read integer vectors, which accept every bit pattern, and stores write lanes of the span's own element type. |
| `Sources/RasterWebPDecoder/Support/Array+Spans.swift` | Creates spans from an array's buffer pointers. | Each span is only used inside the closure, while the array keeps its storage alive. |
