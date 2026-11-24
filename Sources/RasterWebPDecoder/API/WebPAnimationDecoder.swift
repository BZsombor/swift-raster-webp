public import RasterWebPCore

/// The position of a frame in the playback of an animation.
public struct WebPFrameTiming: Hashable, Sendable {
    /// The index of the frame, starting from 0.
    public let index: Int

    /// The time at which the frame starts, in milliseconds from the start of the animation.
    public let timestamp: Int

    /// How long the frame is shown, in milliseconds, as stored in the file.
    public let duration: Int
}

/// A frame of an animation, composited onto the whole canvas.
public struct WebPAnimationFrame: Hashable, Sendable {
    /// The canvas after drawing the frame.
    public let image: WebPImage

    /// The index of the frame, starting from 0.
    public let index: Int

    /// The time at which the frame starts, in milliseconds from the start of the animation.
    public let timestamp: Int

    /// How long the frame is shown, in milliseconds, as stored in the file.
    public let duration: Int
}

/// Decodes the frames of an animated WebP file, one after another.
///
/// Each frame is drawn on a canvas that starts transparent, with the blending and disposal that
/// the file specifies, and the decoder returns the whole canvas. A still image decodes as an
/// animation of one frame whose duration is 0.
///
/// ```swift
/// var decoder = try WebPAnimationDecoder(bytes)
/// while let frame = try decoder.nextFrame() {
///     show(frame.image, for: frame.duration)
/// }
/// ```
///
/// The decoder keeps one canvas, plus room for the largest frame that cannot be decoded straight
/// onto it. It does not repeat the animation by itself: call ``reset()`` to play it again.
public struct WebPAnimationDecoder: Sendable {
    /// The properties of the file.
    public let info: WebPImageInfo

    private let bytes: [UInt8]
    private let options: WebPDecodingOptions

    /// A reader before the first frame, or `nil` for a still image.
    private let firstFrame: AnimationFrameReader?
    private var reader: AnimationFrameReader?
    private var compositor: FrameCompositor
    private var canvas: [UInt32] = []
    private var nextIndex = 0
    private var nextTimestamp = 0
    private var failure: WebPError?

    /// Creates a decoder for a complete WebP file.
    ///
    /// - Parameters:
    ///   - bytes: The contents of the file. The decoder shares the array's storage.
    ///   - options: The options for decoding every frame.
    /// - Throws: A `WebPError` if the file is invalid or exceeds the limits.
    public init(_ bytes: [UInt8], options: WebPDecodingOptions = WebPDecodingOptions()) throws(WebPError) {
        let layout = try bytes.withElementSpan { (span) throws(WebPError) in
            try WebPFileLayout(parsing: span)
        }
        let limits = options.limits
        try limits.validateCanvas(width: layout.info.width, height: layout.info.height)
        if let animation = layout.info.animation {
            guard animation.frameCount <= limits.maximumFrameCount else {
                throw WebPError(.frameLimitExceeded)
            }
            guard layout.framePixelCount <= limits.maximumAnimationPixelCount else {
                throw WebPError(.animationPixelLimitExceeded)
            }
        }

        info = layout.info
        self.bytes = bytes
        self.options = options
        firstFrame = layout.frames
        reader = layout.frames
        compositor = FrameCompositor(canvasWidth: info.width, canvasHeight: info.height)
    }

    /// The properties of every frame, read from the file without decoding pixels.
    ///
    /// - Complexity: O(*n*), where *n* is the number of frames, on every access.
    public var frames: [WebPFrameInfo] {
        guard var reader = firstFrame else {
            return [WebPFrameInfo(still: info)]
        }

        var frames: [WebPFrameInfo] = []
        frames.reserveCapacity(info.animation?.frameCount ?? 0)
        bytes.withElementSpan { span in
            // The initializer validated every frame, so reading them again cannot fail.
            while let frame = try? reader.next(in: span) {
                frames.append(frame.info)
            }
        }
        return frames
    }

    /// Decodes the next frame and returns the canvas with it.
    ///
    /// - Returns: The next frame, or `nil` after the last one.
    /// - Throws: A `WebPError` if the frame is invalid or exceeds the limits. After an error,
    ///   every call throws it again until ``reset()``.
    public mutating func nextFrame() throws(WebPError) -> WebPAnimationFrame? {
        if firstFrame == nil {
            guard try beginStillFrame() else {
                return nil
            }
            let image = try WebPDecoder.decode(bytes, options: options)
            return WebPAnimationFrame(image: image, index: 0, timestamp: 0, duration: 0)
        }

        guard let timing = try advance() else {
            return nil
        }
        let image = try unsafe WebPDecoder.makeImage(width: info.width, height: info.height, options: options) {
            storage in
            unsafe copyCanvas(to: storage)
            unsafe WebPDecoder.convertInPlace(storage, width: info.width, height: info.height, options: options)
        }
        return WebPAnimationFrame(
            image: image,
            index: timing.index,
            timestamp: timing.timestamp,
            duration: timing.duration
        )
    }

    /// Decodes the next frame and writes the canvas with it into memory that the caller provides.
    ///
    /// - Parameters:
    ///   - output: The memory that receives the pixels of the canvas.
    ///   - bytesPerRow: The distance between the starts of consecutive rows in `output`.
    /// - Returns: The timing of the frame, or `nil` after the last one.
    /// - Throws: A `WebPError` if the frame is invalid or exceeds the limits, or if `output`
    ///   cannot hold the canvas. After an error in a frame, every call throws it again until
    ///   ``reset()``.
    public mutating func nextFrame(
        into output: inout MutableSpan<UInt8>,
        bytesPerRow: Int
    ) throws(WebPError) -> WebPFrameTiming? {
        try WebPDecoder.validate(
            &output,
            bytesPerRow: bytesPerRow,
            width: info.width,
            height: info.height,
            options: options
        )

        if firstFrame == nil {
            guard try beginStillFrame() else {
                return nil
            }
            _ = try bytes.withElementSpan { (span) throws(WebPError) in
                try WebPDecoder.decode(span, into: &output, bytesPerRow: bytesPerRow, options: options)
            }
            return WebPFrameTiming(index: 0, timestamp: 0, duration: 0)
        }

        guard let timing = try advance() else {
            return nil
        }
        if WebPDecoder.acceptsWorkingPixels(&output, bytesPerRow: bytesPerRow, width: info.width, options: options) {
            unsafe withRawStorage(of: &output) { storage in
                unsafe copyCanvas(to: storage)
                unsafe WebPDecoder.convertInPlace(storage, width: info.width, height: info.height, options: options)
            }
        } else {
            canvas.withElementSpan { pixels in
                PixelConversion.writeRows(
                    of: pixels,
                    width: info.width,
                    height: info.height,
                    into: &output,
                    bytesPerRow: bytesPerRow,
                    options: options
                )
            }
        }
        return timing
    }

    /// Returns to the first frame, with a transparent canvas, to play the animation again.
    public mutating func reset() {
        reader = firstFrame
        nextIndex = 0
        nextTimestamp = 0
        failure = nil
        compositor.reset()
        canvas.withMutableElementSpan { pixels in
            pixels.update(repeating: 0)
        }
    }

    /// Records the single frame of a still image and returns whether it is still to come.
    private mutating func beginStillFrame() throws(WebPError) -> Bool {
        if let failure {
            throw failure
        }
        guard nextIndex == 0 else {
            return false
        }
        nextIndex = 1
        return true
    }

    /// Draws the next frame of the animation on the canvas.
    private mutating func advance() throws(WebPError) -> WebPFrameTiming? {
        if let failure {
            throw failure
        }

        // Moving the state into locals lets the closures below use it without overlapping
        // accesses to `self`, and without copying the buffers.
        var canvas: [UInt32] = []
        var compositor = FrameCompositor(canvasWidth: 0, canvasHeight: 0)
        var reader = reader
        swap(&canvas, &self.canvas)
        swap(&compositor, &self.compositor)
        defer {
            swap(&canvas, &self.canvas)
            swap(&compositor, &self.compositor)
        }
        if canvas.isEmpty {
            canvas = [UInt32](repeating: 0, count: info.width * info.height)
        }

        let limit = options.limits.maximumMemoryByteCount
        let canvasCount = canvas.count
        do throws(WebPError) {
            let duration = try bytes.withElementSpan { (span) throws(WebPError) -> Int? in
                guard let frame = try reader?.next(in: span) else {
                    return nil
                }
                try canvas.withMutableElementSpan { (pixels) throws(WebPError) in
                    var budget = MemoryBudget(limit: limit)
                    try budget.reserve(count: canvasCount, elementSize: MemoryLayout<UInt32>.stride)
                    try compositor.draw(frame, from: span, on: &pixels, budget: budget)
                }
                return frame.info.duration
            }
            guard let duration else {
                return nil
            }

            self.reader = reader
            let timing = WebPFrameTiming(index: nextIndex, timestamp: nextTimestamp, duration: duration)
            nextIndex += 1
            nextTimestamp += duration
            return timing
        } catch {
            failure = error
            throw error
        }
    }

    /// Copies the canvas to the start of `storage`, which holds at least four bytes per pixel.
    private func copyCanvas(to storage: UnsafeMutableRawBufferPointer) {
        let copy: (UnsafeRawBufferPointer) -> Void = { pixels in
            unsafe storage.copyMemory(from: pixels)
        }
        // Swift 6.3 requires this marker here, while Swift 6.4 reports it as unnecessary.
        #if compiler(>=6.4)
            canvas.withUnsafeBytes(copy)
        #else
            unsafe canvas.withUnsafeBytes(copy)
        #endif
    }
}
