# Unsafe code audit

Every use of `unsafe` in the library is listed here with the invariant that makes it correct.

| Location | Operation | Invariant |
|---|---|---|
| `Sources/RasterWebPCore/Container/WebPImageInfo+Parsing.swift`, `init(parsing: [UInt8])` | Creates a `Span` from the array's buffer pointer. | The span is only used inside the closure, while the array keeps its storage alive. |
