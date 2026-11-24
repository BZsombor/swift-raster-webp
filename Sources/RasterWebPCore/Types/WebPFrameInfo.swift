/// How a frame of an animation is combined with the canvas.
public enum WebPFrameBlending: Hashable, Sendable {
    /// The frame is alpha-blended over the canvas.
    case alphaBlend

    /// The frame replaces the pixels of the canvas that it covers.
    case overwrite
}

/// What happens to the area of a frame before the next frame is drawn.
public enum WebPFrameDisposal: Hashable, Sendable {
    /// The canvas keeps the frame.
    case none

    /// The area of the frame becomes transparent.
    case background
}

/// The properties of one frame of an animation, read without decoding its pixels.
public struct WebPFrameInfo: Hashable, Sendable {
    /// The horizontal position of the frame on the canvas, in pixels.
    public let x: Int

    /// The vertical position of the frame on the canvas, in pixels.
    public let y: Int

    /// The width of the frame in pixels.
    public let width: Int

    /// The height of the frame in pixels.
    public let height: Int

    /// How long the frame is shown, in milliseconds, as stored in the file.
    public let duration: Int

    /// How the frame is combined with the canvas.
    public let blending: WebPFrameBlending

    /// What happens to the area of the frame before the next frame is drawn.
    public let disposal: WebPFrameDisposal

    /// The compression of the frame, either ``WebPCompression/lossy`` or ``WebPCompression/lossless``.
    public let compression: WebPCompression

    /// Whether the frame contains transparency information.
    public let hasAlpha: Bool
}

extension WebPFrameInfo {
    /// The single frame that a still image is when it decodes as an animation.
    package init(still info: WebPImageInfo) {
        self.init(
            x: 0,
            y: 0,
            width: info.width,
            height: info.height,
            duration: 0,
            blending: .overwrite,
            disposal: .none,
            compression: info.compression,
            hasAlpha: info.hasAlpha
        )
    }
}
