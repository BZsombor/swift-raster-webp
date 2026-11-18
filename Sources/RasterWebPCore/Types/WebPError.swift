/// An error produced while reading WebP data.
///
/// Inspect ``kind`` to react to a category of failure. New kinds and more specific
/// descriptions can be added without breaking source compatibility.
public struct WebPError: Error, Hashable, Sendable {
    /// A category of WebP failure.
    public struct Kind: Hashable, Sendable {
        private let rawValue: UInt8

        private init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// The data does not start with a WebP file signature.
        public static var notWebP: Kind { Kind(rawValue: 0) }

        /// The data ends before the end of the file declared in its header.
        public static var truncated: Kind { Kind(rawValue: 1) }

        /// The RIFF container structure violates the WebP specification.
        public static var malformedContainer: Kind { Kind(rawValue: 2) }

        /// An image bitstream violates the WebP specification.
        public static var malformedBitstream: Kind { Kind(rawValue: 3) }
    }

    let detail: Detail

    init(_ detail: Detail) {
        self.detail = detail
    }

    /// The category of this failure.
    public var kind: Kind {
        detail.kind
    }
}

extension WebPError: CustomStringConvertible {
    /// A human-readable explanation of this failure.
    public var description: String {
        detail.message
    }
}

extension WebPError {
    /// The precise reason for a failure.
    enum Detail: UInt8 {
        case notWebP
        case truncated

        case invalidRIFFSize
        case incompleteChunkHeader
        case chunkExceedsContainer
        case noChunks
        case unexpectedFirstChunk
        case invalidVP8XSize
        case canvasTooLarge
        case missingImageData
        case canvasSizeMismatch
        case duplicateANIM
        case frameBeforeANIM
        case missingANIM
        case missingFrames
        case animTooShort
        case anmfTooShort
        case frameExceedsCanvas
        case frameMissingImageData
        case frameSizeMismatch

        case vp8HeaderTooShort
        case vp8NotKeyFrame
        case vp8UnknownProfile
        case vp8NotDisplayable
        case vp8PartitionExceedsChunk
        case vp8MissingStartCode
        case vp8EmptyDimension
        case vp8lHeaderTooShort
        case vp8lMissingSignature
        case vp8lUnknownVersion

        var kind: Kind {
            switch self {
            case .notWebP:
                .notWebP
            case .truncated:
                .truncated
            case .invalidRIFFSize, .incompleteChunkHeader, .chunkExceedsContainer, .noChunks,
                .unexpectedFirstChunk, .invalidVP8XSize, .canvasTooLarge, .missingImageData,
                .canvasSizeMismatch, .duplicateANIM, .frameBeforeANIM, .missingANIM, .missingFrames,
                .animTooShort, .anmfTooShort, .frameExceedsCanvas, .frameMissingImageData,
                .frameSizeMismatch:
                .malformedContainer
            case .vp8HeaderTooShort, .vp8NotKeyFrame, .vp8UnknownProfile, .vp8NotDisplayable,
                .vp8PartitionExceedsChunk, .vp8MissingStartCode, .vp8EmptyDimension,
                .vp8lHeaderTooShort, .vp8lMissingSignature, .vp8lUnknownVersion:
                .malformedBitstream
            }
        }

        var message: String {
            switch self {
            case .notWebP: "The data is not a WebP file."
            case .truncated: "The WebP data is truncated."
            case .invalidRIFFSize: "The RIFF size is invalid."
            case .incompleteChunkHeader: "A chunk header is incomplete."
            case .chunkExceedsContainer: "A chunk extends past its container."
            case .noChunks: "The file contains no chunks."
            case .unexpectedFirstChunk: "The first chunk is not an image or VP8X chunk."
            case .invalidVP8XSize: "The VP8X chunk has an invalid size."
            case .canvasTooLarge: "The canvas area is too large."
            case .missingImageData: "The file contains no image data."
            case .canvasSizeMismatch: "The image size differs from the canvas size."
            case .duplicateANIM: "The file contains more than one ANIM chunk."
            case .frameBeforeANIM: "An animation frame precedes the ANIM chunk."
            case .missingANIM: "The animated file has no ANIM chunk."
            case .missingFrames: "The animated file has no frames."
            case .animTooShort: "The ANIM chunk is too short."
            case .anmfTooShort: "An ANMF chunk is too short."
            case .frameExceedsCanvas: "An animation frame exceeds the canvas."
            case .frameMissingImageData: "An animation frame has no image data."
            case .frameSizeMismatch: "A frame's image size differs from its header."
            case .vp8HeaderTooShort: "The VP8 header is too short."
            case .vp8NotKeyFrame: "The VP8 frame is not a key frame."
            case .vp8UnknownProfile: "The VP8 profile is unknown."
            case .vp8NotDisplayable: "The VP8 frame is not displayable."
            case .vp8PartitionExceedsChunk: "The first VP8 partition exceeds its chunk."
            case .vp8MissingStartCode: "The VP8 start code is missing."
            case .vp8EmptyDimension: "The VP8 image has an empty dimension."
            case .vp8lHeaderTooShort: "The VP8L header is too short."
            case .vp8lMissingSignature: "The VP8L signature is missing."
            case .vp8lUnknownVersion: "The VP8L version is unknown."
            }
        }
    }
}
