# ADR 0003: Implement from the specifications

**Status:** Accepted

## Context

swift-raster-webp is an independent implementation of WebP. Mature libraries in other languages solve the same problems, and they are valuable for learning and for checking results. The code in this repository must still be our own work.

## Decision

The WebP specifications are the only normative source:

- [RFC 9649: WebP Image Format](https://www.rfc-editor.org/rfc/rfc9649.html)
- [RFC 6386: VP8 Data Format and Decoding Guide](https://www.rfc-editor.org/rfc/rfc6386.html)

Other implementations, such as libwebp and image-webp, are references only.

**Allowed:**

- Reading them to learn how a problem can be solved.
- Comparing approaches, performance and behavior.
- Using their programs and test data to verify our results.
- Applying a general technique, written independently in Swift for this codebase.

**Not allowed:**

- Copying their code, including small fragments.
- Translating or porting their code to Swift, even when it is restructured afterward.
- Copying their tables or constants. Take these from the specifications, or derive them independently.

Where a specification leaves behavior open, we may match another implementation's observable output for compatibility. The code that produces that output is still written independently.

## Consequences

Contributors must not submit code derived from another implementation. Reviewers can ask how a non-obvious algorithm or table was derived.
