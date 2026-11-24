# Contributing

Thank you for helping to improve swift-raster-webp.

## Development

You need Swift 6.3 or later.

```bash
swift test
```

The conformance tests use the libwebp test corpus, which is not stored in this repository:

```bash
./Scripts/fetch-corpus.sh
swift test
```

Check the formatting before opening a pull request:

```bash
swift format lint --strict --recursive Package.swift Sources Tests
```

## Project rules

- The library has no external dependencies and does not import Foundation.
- Implement features from RFC 9649 and RFC 6386. Other implementations, such as libwebp and image-webp, are references only: you can learn from them and compare results, but do not copy, translate or port their code. See [ADR 0003](docs/adr/0003-implementation-sources.md).
- Every parser and decoder must treat its input as untrusted.
- Each use of `unsafe` needs a comment that proves its invariant and an entry in [docs/unsafe-audit.md](docs/unsafe-audit.md).
- Performance changes need a benchmark result in the pull request.

## Maintainer tools

The tools use the libwebp command-line programs as a reference.

Regenerate the unit test fixtures:

```bash
swift run --package-path Tools webp-tools fixtures Tests/RasterWebPCoreTests/Fixtures
swift run --package-path Tools webp-tools decoder-fixtures Tests/RasterWebPDecoderTests/Fixtures
swift run --package-path Tools webp-tools animation-fixtures Tests/RasterWebPDecoderTests/Fixtures
```

Regenerate the conformance data:

```bash
swift run --package-path Tools webp-tools golden .corpus/libwebp-test-data Tests/ConformanceTests/Golden/libwebp-test-data.tsv
swift run --package-path Tools webp-tools golden Tests/RasterWebPDecoderTests/Fixtures Tests/RasterWebPDecoderTests/Golden/fixtures.tsv
swift run --package-path Tools webp-tools animation-golden Tests/RasterWebPDecoderTests/Fixtures Tests/RasterWebPDecoderTests/Golden/animations.tsv
```

The animation tools compile `Tools/Oracle/anim-oracle.c`, which renders animations with libwebp's `WebPAnimDecoder`. They need a C compiler, `pkg-config` and the libwebp development files (`libwebpdemux`).

Compare the decoder with `dwebp` on random images:

```bash
swift run -c release --package-path Tools webp-tools differential 500
swift run -c release --package-path Tools webp-tools animation-differential 200
```

Compare decoding speed with `dwebp`:

```bash
swift run -c release --package-path Tools webp-tools speed image.webp
swift run -c release --package-path Tools webp-tools animation-speed animation.webp
```

Fuzz for one minute. The targets are `container`, `decoder`, `vp8l`, `vp8` and `animation`:

```bash
docker run --rm -v "$PWD:/work:ro" -w /work swift:6.3-noble Fuzz/run.sh decoder 60
```

Run the benchmarks:

```bash
cd Benchmarks && BENCHMARK_DISABLE_JEMALLOC=true swift package --disable-sandbox --allow-writing-to-package-directory benchmark
```

## License

Contributions are accepted under the [Apache License 2.0](LICENSE).
