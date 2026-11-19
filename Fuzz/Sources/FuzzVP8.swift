// A structure-aware libFuzzer entry point for VP8 key frames.
//
// Random mutations rarely produce a frame header whose fields and partition sizes agree, so most
// inputs would stop before the first macroblock. This target writes a valid header with a
// boolean encoder, choosing every field from the fuzzer's input, and fills the macroblock data
// and token partitions with the rest of the input. Any bytes form a valid boolean-coded stream,
// so the decoder reaches the prediction, transform and filter code with many settings.

import RasterWebPDecoder

private struct InputReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0

    var remaining: Int { bytes.count - position }

    mutating func byte() -> UInt8 {
        guard position < bytes.count else {
            return 0
        }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func value(below bound: Int) -> Int {
        (Int(byte()) << 8 | Int(byte())) % bound
    }

    mutating func flag() -> Bool {
        byte() & 1 == 1
    }

    mutating func take(_ count: Int) -> [UInt8] {
        (0..<min(count, remaining)).map { _ in byte() }
    }
}

/// The boolean entropy encoder of RFC 6386, section 7.3.
private struct BoolEncoder {
    var bytes: [UInt8] = []
    private var range: UInt32 = 255
    private var bottom: UInt32 = 0
    private var bitCount = 24

    mutating func write(_ bit: Bool, probability: UInt32 = 128) {
        let split = 1 + (((range - 1) * probability) >> 8)
        if bit {
            bottom &+= split
            range -= split
        } else {
            range = split
        }
        while range < 128 {
            range <<= 1
            if bottom & (1 << 31) != 0 {
                var index = bytes.count - 1
                while index >= 0, bytes[index] == 255 {
                    bytes[index] = 0
                    index -= 1
                }
                bytes[index] += 1
            }
            bottom <<= 1
            bitCount -= 1
            if bitCount == 0 {
                bytes.append(UInt8(truncatingIfNeeded: bottom >> 24))
                bottom &= (1 << 24) - 1
                bitCount = 8
            }
        }
    }

    mutating func literal(_ value: Int, bits: Int) {
        for bit in (0..<bits).reversed() {
            write((value >> bit) & 1 == 1)
        }
    }

    /// Writes an optional signed value: a presence flag, the magnitude and the sign.
    mutating func optionalSigned(bits: Int, input: inout InputReader) {
        let present = input.flag()
        write(present)
        if present {
            literal(input.value(below: 1 << bits), bits: bits)
            write(input.flag())
        }
    }

    mutating func flush() {
        for _ in 0..<32 {
            write(false)
        }
    }
}

/// Writes the frame header fields of RFC 6386, sections 9.2 to 9.6, and returns the
/// partition count.
private func writeHeader(_ encoder: inout BoolEncoder, input: inout InputReader) -> Int {
    // Color space and clamping type.
    encoder.write(input.flag())
    encoder.write(input.flag())

    let segmentation = input.flag()
    encoder.write(segmentation)
    if segmentation {
        let updatesMap = input.flag()
        let updatesData = input.flag()
        encoder.write(updatesMap)
        encoder.write(updatesData)
        if updatesData {
            encoder.write(input.flag())
            for _ in 0..<4 {
                encoder.optionalSigned(bits: 7, input: &input)
            }
            for _ in 0..<4 {
                encoder.optionalSigned(bits: 6, input: &input)
            }
        }
        if updatesMap {
            for _ in 0..<3 {
                let present = input.flag()
                encoder.write(present)
                if present {
                    encoder.literal(Int(input.byte()), bits: 8)
                }
            }
        }
    }

    // Filter type, level and sharpness, then the optional filter deltas.
    encoder.write(input.flag())
    encoder.literal(input.value(below: 64), bits: 6)
    encoder.literal(input.value(below: 8), bits: 3)
    let deltas = input.flag()
    encoder.write(deltas)
    if deltas {
        let updates = input.flag()
        encoder.write(updates)
        if updates {
            for _ in 0..<8 {
                encoder.optionalSigned(bits: 6, input: &input)
            }
        }
    }

    let partitionBits = input.value(below: 4)
    encoder.literal(partitionBits, bits: 2)

    // The quantizer index and its five deltas, then the entropy refresh flag.
    encoder.literal(input.value(below: 128), bits: 7)
    for _ in 0..<5 {
        encoder.optionalSigned(bits: 4, input: &input)
    }
    encoder.write(input.flag())
    return 1 << partitionBits
}

private func littleEndian(_ value: Int, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

private func chunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
    var bytes = Array(tag.utf8) + littleEndian(payload.count, count: 4) + payload
    if payload.count % 2 == 1 {
        bytes.append(0)
    }
    return bytes
}

/// Decodes one structured key frame built from an input generated by libFuzzer.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzVP8(_ data: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    var input = InputReader(bytes: UnsafeBufferPointer(start: data, count: count))

    let width = 1 + input.value(below: 96)
    let height = 1 + input.value(below: 96)
    let hasAlpha = input.byte() & 3 == 0
    let alphaHeader = input.byte()

    var encoder = BoolEncoder()
    let partitionCount = writeHeader(&encoder, input: &input)

    // The rest of the first partition holds the probability updates and the macroblock modes.
    let firstPartitionShare = 1 + Int(input.byte())
    let modeBytes = input.take(input.remaining * firstPartitionShare / 512)
    for byte in modeBytes {
        encoder.literal(Int(byte), bits: 8)
    }
    encoder.flush()
    let firstPartition = encoder.bytes

    // Every token partition except the last has its size before the partition data.
    let alphaBytes = hasAlpha ? input.take(width * height / 2) : []
    var partitions: [[UInt8]] = []
    for index in 0..<partitionCount {
        let share = index == partitionCount - 1 ? input.remaining : input.remaining / (partitionCount - index)
        partitions.append(input.take(share))
    }

    // The frame tag: a key frame, a version, shown, and the size of the first partition.
    let version = Int(alphaHeader >> 6)
    let tag = version << 1 | 1 << 4 | firstPartition.count << 5
    var frame = littleEndian(tag, count: 3) + [0x9D, 0x01, 0x2A]
    frame += littleEndian(width, count: 2) + littleEndian(height, count: 2)
    frame += firstPartition
    for partition in partitions.dropLast() {
        frame += littleEndian(partition.count, count: 3)
    }
    for partition in partitions {
        frame += partition
    }

    var body = Array("WEBP".utf8)
    if hasAlpha {
        // An extended file whose alpha chunk is raw or VP8L-coded, with any filter.
        let flags: [UInt8] = [0x10, 0, 0, 0]
        body += chunk("VP8X", flags + littleEndian(width - 1, count: 3) + littleEndian(height - 1, count: 3))
        body += chunk("ALPH", [alphaHeader & 0x3F] + alphaBytes)
    }
    body += chunk("VP8 ", frame)
    let file = Array("RIFF".utf8) + littleEndian(body.count, count: 4) + body

    var options = WebPDecodingOptions()
    options.limits.maximumPixelCount = 1 << 16
    options.limits.maximumMemoryByteCount = 1 << 25
    _ = try? WebPDecoder.decode(file, options: options)
    return 0
}
