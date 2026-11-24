public import RasterWebPCore

/// Decodes WebP images.
///
/// For an animation, the decoder returns its first frame as the animation shows it. Use
/// ``WebPAnimationDecoder`` to decode every frame.
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
        return try unsafe makeImage(width: source.width, height: source.height, options: options) {
            (storage) throws(WebPError) in
            try unsafe decodeInPlace(bytes, source: source, storage: storage, options: options)
        }
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
        var output = output
        return try decode(bytes, into: &output, bytesPerRow: bytesPerRow, options: options)
    }

    /// Decodes a complete WebP file into memory that the caller provides.
    static func decode(
        _ bytes: Span<UInt8>,
        into output: inout MutableSpan<UInt8>,
        bytesPerRow: Int,
        options: WebPDecodingOptions
    ) throws(WebPError) -> WebPImageInfo {
        let source = try DecodingSource(bytes, limits: options.limits)
        try validate(&output, bytesPerRow: bytesPerRow, width: source.width, height: source.height, options: options)

        if acceptsWorkingPixels(&output, bytesPerRow: bytesPerRow, width: source.width, options: options) {
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

    /// Checks that `output` can hold an image of the given size.
    static func validate(
        _ output: inout MutableSpan<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        options: WebPDecodingOptions
    ) throws(WebPError) {
        guard bytesPerRow >= width * options.pixelFormat.bytesPerPixel else {
            throw WebPError(.invalidBytesPerRow)
        }
        let (rowsSize, overflow) = (height - 1).multipliedReportingOverflow(by: bytesPerRow)
        guard !overflow, rowsSize <= output.count - width * options.pixelFormat.bytesPerPixel else {
            throw WebPError(.outputBufferTooSmall)
        }
    }

    /// Returns whether `output` can serve as the working storage of four-byte pixels.
    static func acceptsWorkingPixels(
        _ output: inout MutableSpan<UInt8>,
        bytesPerRow: Int,
        width: Int,
        options: WebPDecodingOptions
    ) -> Bool {
        let isTightlyPacked = bytesPerRow == width * options.pixelFormat.bytesPerPixel
        let isAligned = unsafe withRawStorage(of: &output) { storage in
            UInt(bitPattern: storage.baseAddress) % 4 == 0
        }
        return isAligned && isTightlyPacked && options.pixelFormat.bytesPerPixel == 4
    }

    /// Creates an image whose pixels `fill` writes into storage of four bytes per pixel.
    static func makeImage(
        width: Int,
        height: Int,
        options: WebPDecodingOptions,
        fill: (UnsafeMutableRawBufferPointer) throws(WebPError) -> Void
    ) throws(WebPError) -> WebPImage {
        let bytesPerRow = width * options.pixelFormat.bytesPerPixel

        // Decoding happens in place, so the storage must hold four bytes for every pixel.
        let capacity = width * height * 4
        var failure: WebPError?
        let pixels = unsafe [UInt8](unsafeUninitializedCapacity: capacity) { buffer, initializedCount in
            unsafe buffer.initialize(repeating: 0)
            initializedCount = bytesPerRow * height
            do throws(WebPError) {
                try unsafe fill(UnsafeMutableRawBufferPointer(buffer))
            } catch {
                failure = error
                initializedCount = 0
            }
        }
        if let failure {
            throw failure
        }

        return WebPImage(
            width: width,
            height: height,
            pixelFormat: options.pixelFormat,
            alphaMode: options.alphaMode,
            bytesPerRow: bytesPerRow,
            pixels: pixels
        )
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
    ///
    /// It runs once per image, so it is kept out of line to avoid a copy in every caller.
    @inline(never)
    private static func decodeInPlace(
        _ bytes: Span<UInt8>,
        source: DecodingSource,
        storage: UnsafeMutableRawBufferPointer,
        options: WebPDecodingOptions
    ) throws(WebPError) {
        let pixelCount = source.width * source.height
        var failure: WebPError?

        unsafe storage.withMemoryRebound(to: UInt32.self) { buffer in
            var pixels = unsafe UnsafeMutableBufferPointer(rebasing: buffer[..<pixelCount]).mutableSpan
            do throws(WebPError) {
                var budget = MemoryBudget(limit: options.limits.maximumMemoryByteCount)
                try budget.reserve(count: pixelCount, elementSize: MemoryLayout<UInt32>.stride)
                switch source.content {
                case .still(let image):
                    try decodeImage(bytes, image, budget: &budget, into: &pixels)
                case .animation(var frames):
                    // The first frame, drawn on a transparent canvas, is what the animation shows first.
                    pixels.update(repeating: 0)
                    if let frame = try frames.next(in: bytes) {
                        var compositor = FrameCompositor(canvasWidth: source.width, canvasHeight: source.height)
                        try compositor.draw(frame, from: bytes, on: &pixels, budget: budget)
                    }
                }
            } catch {
                failure = error
            }
        }
        if let failure {
            throw failure
        }
        unsafe convertInPlace(storage, width: source.width, height: source.height, options: options)
    }

    /// Converts ARGB pixels at the start of `storage` into the output format of `options`.
    static func convertInPlace(
        _ storage: UnsafeMutableRawBufferPointer,
        width: Int,
        height: Int,
        options: WebPDecodingOptions
    ) {
        let pixelCount = width * height
        unsafe storage.withMemoryRebound(to: UInt32.self) { buffer in
            var pixels = unsafe buffer.mutableSpan
            if options.alphaMode == .premultiplied {
                PixelConversion.premultiply(&pixels, count: pixelCount)
            }
            if options.pixelFormat.layout == .rgba {
                PixelConversion.storeRGBA(&pixels, count: pixelCount)
            } else {
                PixelConversion.storeBGRA(&pixels, count: pixelCount)
            }
        }

        if options.pixelFormat.bytesPerPixel == 3 {
            var output = unsafe storage.assumingMemoryBound(to: UInt8.self).mutableSpan
            PixelConversion.packThreeByteRows(
                in: &output,
                width: width,
                height: height,
                bytesPerRow: width * 3,
                swapRedAndBlue: options.pixelFormat.layout == .rgb
            )
        }
    }

    /// Decodes one image bitstream, a still image or an animation frame, into ARGB pixels.
    static func decodeImage(
        _ bytes: Span<UInt8>,
        _ image: ImageSource,
        budget: inout MemoryBudget,
        into pixels: inout MutableSpan<UInt32>
    ) throws(WebPError) {
        if image.isLossless {
            try LosslessDecoder.decode(
                input: bytes,
                bitstream: image.bitstream,
                width: image.width,
                height: image.height,
                budget: budget,
                into: &pixels
            )
            return
        }

        // The alpha plane goes straight into the top byte of the output pixels, and the color
        // conversion keeps it there.
        let hasAlpha = image.alphaPayload != nil
        if let alphaPayload = image.alphaPayload {
            try AlphaDecoder.decode(
                input: bytes,
                payload: alphaPayload,
                width: image.width,
                height: image.height,
                budget: budget,
                into: &pixels
            )
        }

        var converter = YUVRowConverter(width: image.width, height: image.height)
        try LossyDecoder.decode(
            input: bytes,
            payload: image.bitstream,
            width: image.width,
            height: image.height,
            budget: &budget
        ) { luma, u, v, rows in
            converter.convert(luma: luma, u: u, v: v, rows: rows, hasAlpha: hasAlpha, into: &pixels)
        }
    }
}

/// The location and size of one image bitstream: a still image or an animation frame.
struct ImageSource {
    private static var losslessHeaderSize: Int { 5 }

    let width: Int
    let height: Int
    let isLossless: Bool

    /// The VP8L bitstream after its header, or the whole payload of a `VP8 ` chunk.
    let bitstream: Range<Int>

    /// The payload of the `ALPH` chunk of a lossy image.
    let alphaPayload: Range<Int>?

    init(width: Int, height: Int, compression: WebPCompression, payload: Range<Int>, alphaPayload: Range<Int>?) {
        self.width = width
        self.height = height
        isLossless = compression == .lossless
        bitstream = isLossless ? (payload.lowerBound + Self.losslessHeaderSize)..<payload.upperBound : payload
        self.alphaPayload = alphaPayload
    }

    init(frame: AnimationFrame) {
        self.init(
            width: frame.info.width,
            height: frame.info.height,
            compression: frame.info.compression,
            payload: frame.imagePayload,
            alphaPayload: frame.alphaPayload
        )
    }
}

extension WebPDecodingLimits {
    /// Checks that a canvas of the given size stays within the pixel and memory limits.
    func validateCanvas(width: Int, height: Int) throws(WebPError) {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw WebPError(.pixelLimitExceeded)
        }
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow, byteCount <= maximumMemoryByteCount else {
            throw WebPError(.memoryLimitExceeded)
        }
    }
}

/// The validated contents of a file for `WebPDecoder`.
private struct DecodingSource {
    enum Content {
        case still(ImageSource)
        case animation(AnimationFrameReader)
    }

    let info: WebPImageInfo
    let content: Content

    var width: Int { info.width }
    var height: Int { info.height }

    init(_ bytes: Span<UInt8>, limits: WebPDecodingLimits) throws(WebPError) {
        let layout = try WebPFileLayout(parsing: bytes)
        info = layout.info
        try limits.validateCanvas(width: info.width, height: info.height)

        if let frames = layout.frames {
            content = .animation(frames)
        } else if let payload = layout.imagePayload {
            content = .still(
                ImageSource(
                    width: info.width,
                    height: info.height,
                    compression: info.compression,
                    payload: payload,
                    alphaPayload: layout.alphaPayload
                )
            )
        } else {
            throw WebPError(.missingImageData)
        }
    }
}
