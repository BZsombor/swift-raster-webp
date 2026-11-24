internal import RasterWebPCore

/// Draws the frames of an animation on a canvas of straight ARGB pixels, as RFC 9649,
/// section 2.7.2, and ADR 0006 describe.
struct FrameCompositor {
    private struct Area {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    let canvasWidth: Int
    let canvasHeight: Int

    /// The decoded pixels of a frame that cannot be decoded straight onto the canvas.
    private var scratch: [UInt32] = []

    /// The area of the previous frame, if it is disposed to the background before the next one.
    private var disposal: Area?

    /// Whether the canvas is entirely transparent once the previous frame is disposed of.
    ///
    /// A frame drawn on such a canvas replaces its pixels instead of blending, as libwebp does.
    private var startsClear = true

    init(canvasWidth: Int, canvasHeight: Int) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    /// Forgets the previous frame, for a canvas that starts over transparent.
    mutating func reset() {
        disposal = nil
        startsClear = true
    }

    /// Disposes of the previous frame and draws `frame` on the canvas.
    ///
    /// - Parameter budget: The memory that remains after the canvas.
    mutating func draw(
        _ frame: AnimationFrame,
        from bytes: Span<UInt8>,
        on canvas: inout MutableSpan<UInt32>,
        budget: MemoryBudget
    ) throws(WebPError) {
        let disposed = disposal
        if let disposed {
            clear(disposed, on: &canvas)
        }

        let info = frame.info
        let image = ImageSource(frame: frame)
        let isClear = startsClear
        var budget = budget

        // A lossy frame without alpha is opaque, so blending it also replaces the canvas.
        let replaces = isClear || info.blending == .overwrite || (info.compression == .lossy && !info.hasAlpha)
        if info.x == 0, info.width == canvasWidth, replaces {
            // A frame that replaces whole rows is decoded straight onto the canvas.
            let rows = (info.y * canvasWidth)..<((info.y + info.height) * canvasWidth)
            try withPart(of: &canvas, rows) { (pixels) throws(WebPError) in
                try WebPDecoder.decodeImage(bytes, image, budget: &budget, into: &pixels)
            }
        } else {
            let count = info.width * info.height
            try budget.reserve(count: count, elementSize: MemoryLayout<UInt32>.stride)
            if scratch.count < count {
                scratch = []
                scratch = [UInt32](repeating: 0, count: count)
            }

            var pixels: [UInt32] = []
            swap(&pixels, &scratch)
            defer { swap(&pixels, &scratch) }
            try pixels.withMutableElementSpan { (storage) throws(WebPError) in
                try withPart(of: &storage, 0..<count) { (framePixels) throws(WebPError) in
                    try WebPDecoder.decodeImage(bytes, image, budget: &budget, into: &framePixels)
                    combine(framePixels.span, info, replaces: replaces, disposed: disposed, on: &canvas)
                }
            }
        }

        let area = Area(x: info.x, y: info.y, width: info.width, height: info.height)
        let coversCanvas = info.width == canvasWidth && info.height == canvasHeight
        disposal = info.disposal == .background ? area : nil
        startsClear = info.disposal == .background && (isClear || coversCanvas)
    }

    /// Makes an area of the canvas transparent black.
    private func clear(_ area: Area, on canvas: inout MutableSpan<UInt32>) {
        for row in area.y..<(area.y + area.height) {
            let start = row * canvasWidth + area.x
            withPart(of: &canvas, start..<(start + area.width)) { pixels in
                pixels.update(repeating: 0)
            }
        }
    }

    /// Writes or blends the decoded pixels of a frame onto its area of the canvas.
    ///
    /// Pixels inside the area that the previous frame left transparent are written, not
    /// blended, as libwebp does.
    private func combine(
        _ frame: Span<UInt32>,
        _ info: WebPFrameInfo,
        replaces: Bool,
        disposed: Area?,
        on canvas: inout MutableSpan<UInt32>
    ) {
        var source = 0
        for row in info.y..<(info.y + info.height) {
            let start = row * canvasWidth + info.x
            let end = start + info.width
            guard !replaces else {
                copy(frame, from: source, to: &canvas, start..<end)
                source &+= info.width
                continue
            }

            // The part of the row inside the disposed area, which may be empty.
            var copied = end..<end
            if let disposed, disposed.y <= row, row < disposed.y + disposed.height {
                let rowStart = row * canvasWidth
                let lower = max(start, rowStart + disposed.x)
                let upper = min(end, rowStart + disposed.x + disposed.width)
                if lower < upper {
                    copied = lower..<upper
                }
            }
            blend(frame, from: source, to: &canvas, start..<copied.lowerBound)
            copy(frame, from: source &+ (copied.lowerBound &- start), to: &canvas, copied)
            blend(frame, from: source &+ (copied.upperBound &- start), to: &canvas, copied.upperBound..<end)
            source &+= info.width
        }
    }

    /// Writes frame pixels, starting at `source`, to a range of the canvas.
    private func copy(
        _ frame: Span<UInt32>,
        from source: Int,
        to canvas: inout MutableSpan<UInt32>,
        _ range: Range<Int>
    ) {
        var source = source
        for destination in range {
            canvas[destination] = frame[source]
            source &+= 1
        }
    }

    /// Blends frame pixels, starting at `source`, over a range of the canvas.
    private func blend(
        _ frame: Span<UInt32>,
        from source: Int,
        to canvas: inout MutableSpan<UInt32>,
        _ range: Range<Int>
    ) {
        var source = source
        for destination in range {
            let pixel = frame[source]
            let alpha = pixel &>> 24
            if alpha == 255 {
                canvas[destination] = pixel
            } else if alpha != 0 {
                canvas[destination] = Self.blend(pixel, over: canvas[destination])
            }
            source &+= 1
        }
    }

    /// Blends a translucent pixel over another, in the integer arithmetic of ADR 0006.
    ///
    /// The source alpha must be between 1 and 254.
    @inline(always)
    static func blend(_ source: UInt32, over destination: UInt32) -> UInt32 {
        let sourceAlpha = source &>> 24
        let destinationFactor = ((destination &>> 24) &* (256 &- sourceAlpha)) &>> 8
        let alpha = sourceAlpha &+ destinationFactor
        let scale = UInt64((1 << 24) / alpha)

        @inline(always)
        func channel(_ shift: UInt32) -> UInt32 {
            let sum =
                ((source &>> shift) & 0xFF) &* sourceAlpha &+ ((destination &>> shift) & 0xFF) &* destinationFactor
            return UInt32(truncatingIfNeeded: (UInt64(sum) &* scale) &>> 24) &<< shift
        }
        return alpha &<< 24 | channel(16) | channel(8) | channel(0)
    }
}
