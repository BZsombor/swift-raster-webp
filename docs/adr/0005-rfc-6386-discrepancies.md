# ADR 0005: Follow the reference decoder where RFC 6386 contradicts itself

**Status:** Accepted

## Context

RFC 6386 states that its reference decoder source code defines the VP8 format, and that the code takes precedence wherever the prose disagrees with it. While implementing the decoder, we found places where the prose or the pseudocode contradicts other parts of the RFC or the behavior of conforming decoders.

## Decision

Where the RFC contradicts itself, the decoder follows the behavior of the reference decoder, implemented from our own reading. The code is still written independently, as [ADR 0003](0003-implementation-sources.md) requires. Each choice is confirmed by bit-exact agreement with `dwebp` on the YUV planes of every lossy file in the libwebp test corpus.

| Topic | What the RFC says | What the decoder does |
|---|---|---|
| Segment feature mode, section 9.3 | Mode 0 means absolute values and mode 1 means deltas | Mode 1 means absolute values and mode 0 means deltas, as section 19.2 states |
| Block types in the token pseudocode, section 13.3 | Y2 blocks use type 0, and luma blocks after a Y2 block use type 1 | Y2 blocks use type 1, and luma blocks after a Y2 block use type 0, as the prose of section 13.3 lists them |
| End-of-block after a zero, section 13.3 pseudocode | `prevCoeffWasZero` becomes true after every token | Only a `DCT_0` token skips the end-of-block branch of the next token, as the prose of section 13.2 describes |
| Neighbor context, section 13.3 pseudocode | A block counts as having coefficients only when a token is not zero | A block counts as having coefficients when it has any token before its end-of-block token |

## Consequences

- A reader who compares the decoder with the RFC's pseudocode finds these differences documented here and in the code comments.
- If a later errata or revision changes the RFC, this record shows which behaviors to recheck.
