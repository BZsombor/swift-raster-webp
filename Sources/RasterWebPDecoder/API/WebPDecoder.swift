public import RasterWebPCore

/// Decodes WebP images.
public enum WebPDecoder {
    /// Decodes a complete WebP file.
    ///
    /// - Parameters:
    ///   - bytes: The contents of the file.
    ///   - options: The options for decoding.
    /// - Returns: The decoded image.
    /// - Throws: A `WebPError` if the file is invalid, unsupported or exceeds the limits.
    public static func decode(
        _ bytes: [UInt8],
        options: WebPDecodingOptions = WebPDecodingOptions()
    ) throws(WebPError) -> WebPImage {
        try bytes.withElementSpan { (span) throws(WebPError) in
            try decode(span, options: options)
        }
    }

    /// Decodes a complete WebP file.
    ///
    /// - Parameters:
    ///   - bytes: The contents of the file.
    ///   - options: The options for decoding.
    /// - Returns: The decoded image.
    /// - Throws: A `WebPError` if the file is invalid, unsupported or exceeds the limits.
    public static func decode(
        _ bytes: Span<UInt8>,
        options: WebPDecodingOptions = WebPDecodingOptions()
    ) throws(WebPError) -> WebPImage {
        let source = try DecodingSource(bytes, limits: options.limits)
        let bytesPerRow = source.width * options.pixelFormat.bytesPerPixel

        // Decoding happens in place, so the storage must hold four bytes for every pixel.
        let capacity = source.width * source.height * 4
        var failure: WebPError?
        let pixels = unsafe [UInt8](unsafeUninitializedCapacity: capacity) { buffer, initializedCount in
            unsafe buffer.initialize(repeating: 0)
            initializedCount = bytesPerRow * source.height
            do throws(WebPError) {
                try unsafe decodeInPlace(
                    bytes,
                    source: source,
                    storage: UnsafeMutableRawBufferPointer(buffer),
                    options: options
                )
            } catch {
                failure = error
                initializedCount = 0
            }
        }
        if let failure {
            throw failure
        }

        return WebPImage(
            width: source.width,
            height: source.height,
            pixelFormat: options.pixelFormat,
            alphaMode: options.alphaMode,
            bytesPerRow: bytesPerRow,
            pixels: pixels
        )
    }

    /// Decodes a complete WebP file into memory that the caller provides.
    ///
    /// - Parameters:
    ///   - bytes: The contents of the file.
    ///   - output: The memory that receives the pixels.
    ///   - bytesPerRow: The distance between the starts of consecutive rows in `output`.
    ///   - options: The options for decoding.
    /// - Returns: The properties of the decoded image.
    /// - Throws: A `WebPError` if the file is invalid, unsupported or exceeds the limits,
    ///   or if `output` cannot hold the image.
    @discardableResult
    public static func decode(
        _ bytes: Span<UInt8>,
        into output: consuming MutableSpan<UInt8>,
        bytesPerRow: Int,
        options: WebPDecodingOptions = WebPDecodingOptions()
    ) throws(WebPError) -> WebPImageInfo {
        let source = try DecodingSource(bytes, limits: options.limits)
        let rowSize = source.width * options.pixelFormat.bytesPerPixel

        guard bytesPerRow >= rowSize else {
            throw WebPError(.invalidBytesPerRow)
        }
        let (rowsSize, overflow) = (source.height - 1).multipliedReportingOverflow(by: bytesPerRow)
        guard !overflow, rowsSize <= output.count - rowSize else {
            throw WebPError(.outputBufferTooSmall)
        }

        let isTightlyPacked = bytesPerRow == rowSize
        let hasFourBytePixels = options.pixelFormat.bytesPerPixel == 4
        let isAligned = unsafe withRawStorage(of: &output) { storage in
            UInt(bitPattern: storage.baseAddress) % 4 == 0
        }

        if isAligned, isTightlyPacked, hasFourBytePixels {
            try unsafe withRawStorage(of: &output) { (storage) throws(WebPError) in
                try unsafe decodeInPlace(bytes, source: source, storage: storage, options: options)
            }
            return source.info
        }

        // The output cannot hold the working pixels, so decode into temporary storage.
        var workingOptions = options
        workingOptions.pixelFormat = options.pixelFormat.bytesPerPixel == 4 ? options.pixelFormat : .bgra8
        let image = try decode(bytes, options: workingOptions)
        copyRows(of: image, to: &output, bytesPerRow: bytesPerRow, format: options.pixelFormat)
        return source.info
    }

    /// Copies four-byte rows into the output, packing them to three bytes when required.
    private static func copyRows(
        of image: WebPImage,
        to output: inout MutableSpan<UInt8>,
        bytesPerRow: Int,
        format: WebPPixelFormat
    ) {
        let swapRedAndBlue = format.layout == .rgb
        var source = 0
        for row in 0..<image.height {
            var destination = row * bytesPerRow
            for _ in 0..<image.width {
                if format.bytesPerPixel == 4 {
                    output[destination] = image.pixels[source]
                    output[destination + 1] = image.pixels[source + 1]
                    output[destination + 2] = image.pixels[source + 2]
                    output[destination + 3] = image.pixels[source + 3]
                } else {
                    output[destination] = image.pixels[source + (swapRedAndBlue ? 2 : 0)]
                    output[destination + 1] = image.pixels[source + 1]
                    output[destination + 2] = image.pixels[source + (swapRedAndBlue ? 0 : 2)]
                }
                source += 4
                destination += format.bytesPerPixel
            }
        }
    }

    /// Decodes into storage that is aligned for `UInt32` and holds four bytes for every pixel,
    /// or exactly the pixels of a tightly packed four-byte format.
    private static func decodeInPlace(
        _ bytes: Span<UInt8>,
        source: DecodingSource,
        storage: UnsafeMutableRawBufferPointer,
        options: WebPDecodingOptions
    ) throws(WebPError) {
        let pixelCount = source.width * source.height
        let workingStorage = unsafe UnsafeMutableRawBufferPointer(rebasing: storage[..<(pixelCount * 4)])
        var failure: WebPError?

        unsafe workingStorage.withMemoryRebound(to: UInt32.self) { buffer in
            var pixels = unsafe buffer.mutableSpan
            do throws(WebPError) {
                var budget = MemoryBudget(limit: options.limits.maximumMemoryByteCount)
                try budget.reserve(count: pixelCount, elementSize: MemoryLayout<UInt32>.stride)
                if source.isLossless {
                    try LosslessDecoder.decode(
                        input: bytes,
                        bitstream: source.bitstream,
                        width: source.width,
                        height: source.height,
                        budget: budget,
                        into: &pixels
                    )
                } else {
                    try decodeLossy(bytes, source: source, budget: &budget, into: &pixels)
                }
            } catch {
                failure = error
                return
            }

            if options.alphaMode == .premultiplied {
                PixelConversion.premultiply(&pixels, count: pixelCount)
            }
            if options.pixelFormat.layout == .rgba {
                PixelConversion.storeRGBA(&pixels, count: pixelCount)
            } else {
                PixelConversion.storeBGRA(&pixels, count: pixelCount)
            }
        }
        if let failure {
            throw failure
        }

        if options.pixelFormat.bytesPerPixel == 3 {
            var output = unsafe workingStorage.assumingMemoryBound(to: UInt8.self).mutableSpan
            PixelConversion.packThreeByteRows(
                in: &output,
                width: source.width,
                height: source.height,
                bytesPerRow: source.width * 3,
                swapRedAndBlue: options.pixelFormat.layout == .rgb
            )
        }
    }
}

extension WebPDecoder {
    /// Decodes a VP8 frame and its optional alpha plane into ARGB pixels.
    fileprivate static func decodeLossy(
        _ bytes: Span<UInt8>,
        source: DecodingSource,
        budget: inout MemoryBudget,
        into pixels: inout MutableSpan<UInt32>
    ) throws(WebPError) {
        var alpha: [UInt8] = []
        if let alphaPayload = source.alphaPayload {
            alpha = try AlphaDecoder.decode(
                input: bytes,
                payload: alphaPayload,
                width: source.width,
                height: source.height,
                budget: &budget
            )
        }

        var converter = YUVRowConverter(width: source.width, height: source.height)
        try LossyDecoder.decode(
            input: bytes,
            payload: source.bitstream,
            width: source.width,
            height: source.height,
            budget: &budget
        ) { luma, u, v, rows in
            alpha.withElementSpan { alpha in
                converter.convert(luma: luma, u: u, v: v, rows: rows, alpha: alpha, into: &pixels)
            }
        }
    }
}

/// The validated location and properties of the image in a file.
private struct DecodingSource {
    private static var losslessHeaderSize: Int { 5 }

    let info: WebPImageInfo

    /// The VP8L bitstream after its header, or the whole payload of a `VP8 ` chunk.
    let bitstream: Range<Int>

    /// The payload of the `ALPH` chunk of a lossy image.
    let alphaPayload: Range<Int>?

    var isLossless: Bool { info.compression == .lossless }

    var width: Int { info.width }
    var height: Int { info.height }

    init(_ bytes: Span<UInt8>, limits: WebPDecodingLimits) throws(WebPError) {
        let layout = try WebPFileLayout(parsing: bytes)
        info = layout.info

        guard !info.isAnimated, let payload = layout.imagePayload else {
            throw WebPError(.animationDecodingUnsupported)
        }
        let (pixelCount, overflow) = info.width.multipliedReportingOverflow(by: info.height)
        guard !overflow, pixelCount <= limits.maximumPixelCount else {
            throw WebPError(.pixelLimitExceeded)
        }
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow, byteCount <= limits.maximumMemoryByteCount else {
            throw WebPError(.memoryLimitExceeded)
        }

        if info.compression == .lossless {
            bitstream = (payload.lowerBound + Self.losslessHeaderSize)..<payload.upperBound
        } else {
            bitstream = payload
        }
        alphaPayload = layout.alphaPayload
    }
}
