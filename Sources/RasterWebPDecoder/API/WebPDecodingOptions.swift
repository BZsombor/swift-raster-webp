/// The memory layout of decoded pixels.
public struct WebPPixelFormat: Hashable, Sendable {
    enum Layout: Hashable, Sendable {
        case rgba
        case bgra
        case rgb
        case bgr
    }

    let layout: Layout

    private init(_ layout: Layout) {
        self.layout = layout
    }

    /// Four bytes per pixel, in red, green, blue, alpha order.
    public static var rgba8: WebPPixelFormat { WebPPixelFormat(.rgba) }

    /// Four bytes per pixel, in blue, green, red, alpha order.
    public static var bgra8: WebPPixelFormat { WebPPixelFormat(.bgra) }

    /// Three bytes per pixel, in red, green, blue order, without alpha.
    public static var rgb8: WebPPixelFormat { WebPPixelFormat(.rgb) }

    /// Three bytes per pixel, in blue, green, red order, without alpha.
    public static var bgr8: WebPPixelFormat { WebPPixelFormat(.bgr) }

    /// The number of bytes that each pixel occupies.
    public var bytesPerPixel: Int {
        switch layout {
        case .rgba, .bgra: 4
        case .rgb, .bgr: 3
        }
    }
}

/// How decoded color channels relate to the alpha channel.
public enum WebPAlphaMode: Hashable, Sendable {
    /// Color channels are independent of the alpha channel.
    case straight

    /// Color channels are multiplied by the alpha channel.
    case premultiplied
}

/// The resources that a decoding operation may use.
public struct WebPDecodingLimits: Hashable, Sendable {
    /// The largest number of pixels that an image may have.
    public var maximumPixelCount: Int

    /// The largest amount of working memory, in bytes, that decoding may allocate.
    public var maximumMemoryByteCount: Int

    /// Creates decoding limits.
    ///
    /// - Parameters:
    ///   - maximumPixelCount: The largest number of pixels that an image may have.
    ///   - maximumMemoryByteCount: The largest amount of working memory, in bytes.
    public init(
        maximumPixelCount: Int = 256_000_000,
        maximumMemoryByteCount: Int = Int.bitWidth == 64 ? 1 << 31 : 1 << 30
    ) {
        self.maximumPixelCount = maximumPixelCount
        self.maximumMemoryByteCount = maximumMemoryByteCount
    }
}

/// The options for decoding a WebP image.
public struct WebPDecodingOptions: Hashable, Sendable {
    /// The memory layout of the decoded pixels.
    public var pixelFormat: WebPPixelFormat

    /// How the decoded color channels relate to the alpha channel.
    public var alphaMode: WebPAlphaMode

    /// The resources that decoding may use.
    public var limits: WebPDecodingLimits

    /// Creates decoding options.
    ///
    /// - Parameters:
    ///   - pixelFormat: The memory layout of the decoded pixels.
    ///   - alphaMode: How the decoded color channels relate to the alpha channel.
    ///   - limits: The resources that decoding may use.
    public init(
        pixelFormat: WebPPixelFormat = .rgba8,
        alphaMode: WebPAlphaMode = .straight,
        limits: WebPDecodingLimits = WebPDecodingLimits()
    ) {
        self.pixelFormat = pixelFormat
        self.alphaMode = alphaMode
        self.limits = limits
    }
}

/// A decoded WebP image.
public struct WebPImage: Hashable, Sendable {
    /// The width of the image in pixels.
    public let width: Int

    /// The height of the image in pixels.
    public let height: Int

    /// The memory layout of ``pixels``.
    public let pixelFormat: WebPPixelFormat

    /// How the color channels of ``pixels`` relate to the alpha channel.
    public let alphaMode: WebPAlphaMode

    /// The number of bytes in each row of ``pixels``.
    public let bytesPerRow: Int

    /// The pixels of the image in scan-line order.
    public let pixels: [UInt8]
}
