# ADR 0002: Verification tooling

**Status:** Accepted

## Context

The first milestone had to establish which verification tools work on which platforms. These results were measured on an Apple M5, with Linux running in Docker on aarch64.

## Findings

| Question | Result |
|---|---|
| Do the tests run on 32-bit WebAssembly? | Yes, with the Swift 6.3.3 SDK and `swift test --swift-sdk`. |
| Does AddressSanitizer work? | Yes. It reports leaks only from XCTest's own runner objects. |
| Does ThreadSanitizer work? | Yes. |
| Does UndefinedBehaviorSanitizer work? | No. Swift 6.3.3 rejects `-sanitize=undefined` on aarch64 Linux. |
| Does libFuzzer work? | Yes, on Linux, by compiling the sources together with the fuzz target. |
| Are instruction counts available? | Yes on macOS. `package-benchmark` did not report them inside a Linux container. |

The cost of a bounds-checked `Span` compared with unsafe pointers in a Huffman loop depends on the compiler:

| Environment | Pointer | Checked `Span` | Cost |
|---|---:|---:|---:|
| Linux, Swift 6.2.4 | 423 million symbols/s | 369 million symbols/s | 13% |
| Linux, Swift 6.3.3 | 456 million symbols/s | 423 million symbols/s | 7% |
| macOS, Swift 6.4.2 | 451 million symbols/s | 441 million symbols/s | 2% |

## Decision

- Run AddressSanitizer and ThreadSanitizer on Linux, without UndefinedBehaviorSanitizer. Swift's own overflow and bounds checks cover most of what it would find.
- Disable LeakSanitizer in the sanitizer job until the XCTest reports are resolved upstream.
- Track instruction counts on macOS runners.
- Keep the bounds-checked `Span` as the default, and use unchecked access only where a benchmark justifies it.

## Still unverified

The first GitHub Actions run must confirm Windows, Android and x86-64 Linux. x86-64 and WebAssembly performance also still need to be measured.
