/// Small fixed values of the VP8 format.
enum VP8Constants {
    /// The probabilities of the key frame luma mode tree. RFC 6386, section 11.2.
    static var keyFrameLumaModeProbabilities: (UInt32, UInt32, UInt32, UInt32) { (145, 156, 163, 128) }

    /// The probabilities of the key frame chroma mode tree. RFC 6386, section 11.4.
    static var keyFrameChromaModeProbabilities: (UInt32, UInt32, UInt32) { (142, 114, 183) }

    /// The band of each coefficient position. RFC 6386, section 13.3.
    static let coefficientBands: [Int] = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7]

    /// The raster position of each coefficient in decoding order. RFC 6386, section 20.16.
    static let zigzag: [Int] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
}

/// The luma prediction modes of a macroblock. RFC 6386, section 8.2.
enum LumaMode: UInt8 {
    case dc = 0
    case vertical = 1
    case horizontal = 2
    case trueMotion = 3
    case subblocks = 4

    /// The subblock mode that stands for this mode in the contexts of neighboring subblocks.
    var contextSubblockMode: UInt8 {
        switch self {
        case .dc, .subblocks: SubblockMode.dc
        case .vertical: SubblockMode.vertical
        case .horizontal: SubblockMode.horizontal
        case .trueMotion: SubblockMode.trueMotion
        }
    }
}

/// The prediction modes of 4x4 luma subblocks. RFC 6386, section 11.2.
enum SubblockMode {
    static var dc: UInt8 { 0 }
    static var trueMotion: UInt8 { 1 }
    static var vertical: UInt8 { 2 }
    static var horizontal: UInt8 { 3 }
    static var leftDown: UInt8 { 4 }
    static var rightDown: UInt8 { 5 }
    static var verticalRight: UInt8 { 6 }
    static var verticalLeft: UInt8 { 7 }
    static var horizontalDown: UInt8 { 8 }
    static var horizontalUp: UInt8 { 9 }
}
