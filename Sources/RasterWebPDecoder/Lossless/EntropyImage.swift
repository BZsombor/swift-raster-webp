internal import RasterWebPCore

/// Decodes the LZ77 and prefix coded pixels of a VP8L image.
enum EntropyImage {
    private static var literalSymbolCount: Int { 256 }
    private static var lengthPrefixCount: Int { 24 }
    private static var colorCacheHashMultiplier: UInt32 { 0x1E35_A7BD }

    /// Decodes `width * height` pixels in scan-line order.
    ///
    /// - Parameters:
    ///   - metaImage: The entropy image, which is empty when one prefix code group covers the image.
    ///   - metaBits: The base-2 logarithm of the entropy image's block size.
    ///   - colorCache: Zero-filled storage for `1 << colorCacheBits` colors, or empty storage
    ///     when `colorCacheBits` is zero.
    static func decode(
        input: Span<UInt8>,
        reader: inout BitReader,
        pixels: inout MutableSpan<UInt32>,
        width: Int,
        height: Int,
        prefixTable: Span<UInt32>,
        groups: Span<PrefixCodeGroup>,
        metaImage: Span<UInt32>,
        metaBits: Int,
        metaWidth: Int,
        colorCache: inout MutableSpan<UInt32>,
        colorCacheBits: Int
    ) throws(WebPError) {
        let pixelCount = width &* height
        let hasMetaImage = !metaImage.isEmpty
        let blockMask = hasMetaImage ? (1 &<< metaBits) &- 1 : Int.max
        let cacheShift = UInt32(truncatingIfNeeded: 32 &- colorCacheBits)
        let firstCacheSymbol = literalSymbolCount &+ lengthPrefixCount

        var position = 0
        var cachedPosition = 0
        var column = 0
        var row = 0
        var group = groups[0]

        while position < pixelCount {
            if column & blockMask == 0, hasMetaImage {
                group = groups[metaGroupIndex(metaImage, column, row, metaBits, metaWidth)]
            }

            reader.refill(input)
            let symbol = group.green.decode(&reader, table: prefixTable)

            if symbol < literalSymbolCount {
                var pixel = UInt32(truncatingIfNeeded: symbol) &<< 8
                if group.hasConstantLiteralBits {
                    pixel |= group.constantLiteralBits
                } else {
                    let red = group.red.decode(&reader, table: prefixTable)
                    reader.refill(input)
                    let blue = group.blue.decode(&reader, table: prefixTable)
                    let alpha = group.alpha.decode(&reader, table: prefixTable)
                    pixel |= UInt32(truncatingIfNeeded: alpha) &<< 24
                    pixel |= UInt32(truncatingIfNeeded: red) &<< 16
                    pixel |= UInt32(truncatingIfNeeded: blue)
                }
                pixels[position] = pixel
                position &+= 1
                column &+= 1
            } else if symbol < firstCacheSymbol {
                let length = readPrefixedValue(symbol &- literalSymbolCount, &reader, input)
                reader.refill(input)
                let distanceSymbol = group.distance.decode(&reader, table: prefixTable)
                let distanceCode = readPrefixedValue(distanceSymbol, &reader, input)
                let distance = scanLineDistance(code: distanceCode, width: width)

                guard distance <= position, length <= pixelCount &- position else {
                    throw WebPError(.vp8lInvalidBackwardReference)
                }

                // Copying forward reproduces the repeating pattern of overlapping references.
                let source = position &- distance
                var offset = 0
                while offset < length {
                    pixels[position &+ offset] = pixels[source &+ offset]
                    offset &+= 1
                }

                position &+= length
                column &+= length
                if hasMetaImage, column < width, position < pixelCount {
                    group = groups[metaGroupIndex(metaImage, column, row, metaBits, metaWidth)]
                }
            } else {
                while cachedPosition < position {
                    let color = pixels[cachedPosition]
                    colorCache[cacheIndex(color, cacheShift)] = color
                    cachedPosition &+= 1
                }
                pixels[position] = colorCache[symbol &- firstCacheSymbol]
                position &+= 1
                column &+= 1
            }

            if column >= width {
                row &+= column / width
                column %= width
                if hasMetaImage, position < pixelCount {
                    group = groups[metaGroupIndex(metaImage, column, row, metaBits, metaWidth)]
                }
                guard !reader.isTruncated else {
                    throw WebPError(.truncated)
                }
            }
        }

        guard !reader.isTruncated else {
            throw WebPError(.truncated)
        }
    }

    /// Returns the prefix code group index for a pixel.
    @inline(always)
    private static func metaGroupIndex(
        _ metaImage: Span<UInt32>,
        _ column: Int,
        _ row: Int,
        _ metaBits: Int,
        _ metaWidth: Int
    ) -> Int {
        let index = (row &>> metaBits) &* metaWidth &+ (column &>> metaBits)
        return Int(truncatingIfNeeded: (metaImage[index] &>> 8) & 0xFFFF)
    }

    /// Returns the color cache slot for a color.
    @inline(always)
    private static func cacheIndex(_ color: UInt32, _ shift: UInt32) -> Int {
        Int(truncatingIfNeeded: (color &* colorCacheHashMultiplier) &>> shift)
    }

    /// Reads a length or distance value from its prefix symbol and extra bits.
    @inline(always)
    private static func readPrefixedValue(
        _ prefix: Int,
        _ reader: inout BitReader,
        _ input: Span<UInt8>
    ) -> Int {
        guard prefix >= 4 else {
            return prefix &+ 1
        }
        let extraBits = (prefix &- 2) &>> 1
        let offset = (2 &+ (prefix & 1)) &<< extraBits
        return offset &+ Int(truncatingIfNeeded: reader.read(extraBits, input)) &+ 1
    }

    /// Converts a distance code into a distance in scan-line order.
    @inline(always)
    private static func scanLineDistance(code: Int, width: Int) -> Int {
        guard code <= 120 else {
            return code &- 120
        }
        let x = Int(DistanceMap.offsets[(code &- 1) &* 2])
        let y = Int(DistanceMap.offsets[(code &- 1) &* 2 &+ 1])
        return max(x &+ y &* width, 1)
    }
}
