# ADR 0001: Separate decoder and encoder modules

**Status:** Accepted

## Context

Most applications only decode WebP, so encoder code should not reach their binaries. Swift modules are also optimization boundaries, which could slow down code that is split across them.

## Measurements

A throwaway prototype ran a VP8L-style literal loop with a bit reader. It used Swift 6.4.2 on an Apple M5, in release mode.

| Bit reader location | Throughput |
|---|---:|
| Same module as the loop | 421 million symbols/s |
| Other module, `@inlinable` | 422 million symbols/s |
| Other module, not inlinable | 244 million symbols/s |

A second prototype linked a decoder with about 400 unused stand-in encoder functions.

| Binary | Stripped size |
|---|---:|
| Decoder module only | 54,560 bytes |
| Decoder and unused encoder in one module | 154,624 bytes |

The linker did not remove the unused public code from the combined module.

## Decision

- Keep `RasterWebPCore`, a decoder module and an encoder module separate. The decoder and encoder targets are added with their milestones.
- `RasterWebP` re-exports the other modules for convenience.
- Hot loops stay inside one module.
- A primitive that must cross a module boundary in a hot path is `@inlinable`.

## Consequences

Decoder-only applications stay smaller. Inlinable primitives become part of the module's compiled interface, so they must stay few and small.
