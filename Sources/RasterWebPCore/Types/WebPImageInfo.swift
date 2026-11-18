/// The compression used by the image data of a WebP file.
public enum WebPCompression: Hashable, Sendable {
    /// All image data uses the lossy VP8 format.
    case lossy

    /// All image data uses the lossless VP8L format.
    case lossless

    /// An animation combines lossy and lossless frames.
    case mixed
}

/// The background color suggested by an animated WebP file.
public struct WebPBackgroundColor: Hashable, Sendable {
    /// The red component.
    public let red: UInt8

    /// The green component.
    public let green: UInt8

    /// The blue component.
    public let blue: UInt8

    /// The alpha component.
    public let alpha: UInt8
}

/// The properties of an animated WebP file.
public struct WebPAnimationInfo: Hashable, Sendable {
    /// The number of frames in the animation.
    public let frameCount: Int

    /// The number of times the animation plays, where `0` means forever.
    public let loopCount: Int

    /// The background color suggested by the file.
    public let backgroundColor: WebPBackgroundColor
}

/// The properties of a WebP image, read without decoding its pixels.
public struct WebPImageInfo: Hashable, Sendable {
    /// The image width in pixels. For an animation, this is the canvas width.
    public let width: Int

    /// The image height in pixels. For an animation, this is the canvas height.
    public let height: Int

    /// The compression used by the image data.
    public let compression: WebPCompression

    /// Whether the file declares or contains transparency information.
    public let hasAlpha: Bool

    /// The animation properties, or `nil` for a still image.
    public let animation: WebPAnimationInfo?

    /// Whether the file contains an ICC color profile.
    public let hasICCProfile: Bool

    /// Whether the file contains EXIF metadata.
    public let hasEXIF: Bool

    /// Whether the file contains XMP metadata.
    public let hasXMP: Bool

    /// Whether the file is an animation.
    public var isAnimated: Bool {
        animation != nil
    }
}
