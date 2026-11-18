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
```

Regenerate the conformance data:

```bash
swift run --package-path Tools webp-tools golden .corpus/libwebp-test-data Tests/ConformanceTests/Golden/libwebp-test-data.tsv
```

Fuzz the container parser for one minute:

```bash
docker run --rm -v "$PWD:/work:ro" -w /work swift:6.3-noble Fuzz/run.sh 60
```

Run the benchmarks:

```bash
cd Benchmarks && BENCHMARK_DISABLE_JEMALLOC=true swift package --disable-sandbox --allow-writing-to-package-directory benchmark
```

## License

Contributions are accepted under the [Apache License 2.0](LICENSE).
