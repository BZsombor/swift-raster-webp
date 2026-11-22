import Foundation

/// The command-line contract that every measuring program of the comparison follows.
///
///     <program> speed <warmup> <runs> <file>...   one JSON line per file with the timings
///     <program> hash <file>...                    the FNV-1a hash of straight RGBA pixels per file
///     <program> decode <file>                     one decode, for measuring peak memory
///     <program> read <file>                       only reads the file, the memory baseline
public enum Bench {
    /// Runs the program.
    ///
    /// - Parameters:
    ///   - decode: Decodes into the library's usual 8-bit output, returning the image size.
    ///   - rgba: Decodes into straight RGBA, four bytes per pixel, for comparing pixels.
    public static func main(
        decode: ([UInt8]) throws -> (width: Int, height: Int),
        rgba: ([UInt8]) throws -> [UInt8]
    ) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments.first {
            case "speed" where arguments.count >= 4:
                let warmup = Int(arguments[1]) ?? 3
                let runs = Int(arguments[2]) ?? 20
                for path in arguments.dropFirst(3) {
                    try speed(path: path, warmup: warmup, runs: runs, decode: decode)
                }
            case "hash":
                for path in arguments.dropFirst() {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    do {
                        print("\(name)\t\(hex(fnv1a(try rgba(try read(path)))))")
                    } catch {
                        print("\(name)\tERROR \(error)")
                    }
                }
            case "decode" where arguments.count == 2:
                print(try decode(try read(arguments[1])).width)
            case "read" where arguments.count == 2:
                print(try read(arguments[1]).count)
            default:
                FileHandle.standardError.write(Data("usage: speed|hash|decode|read\n".utf8))
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Reads a file into one array, without an intermediate copy that would raise the peak
    /// memory of the baseline, like the other languages' programs.
    private static func read(_ path: String) throws -> [UInt8] {
        guard let file = fopen(path, "rb") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { fclose(file) }
        fseek(file, 0, SEEK_END)
        let size = ftell(file)
        fseek(file, 0, SEEK_SET)
        guard size >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return try [UInt8](unsafeUninitializedCapacity: size) { buffer, count in
            count = fread(buffer.baseAddress, 1, size, file)
            guard count == size else {
                throw CocoaError(.fileReadUnknown)
            }
        }
    }

    private static func speed(
        path: String,
        warmup: Int,
        runs: Int,
        decode: ([UInt8]) throws -> (width: Int, height: Int)
    ) throws {
        let bytes = try read(path)
        var size = (width: 0, height: 0)
        for _ in 0..<warmup {
            size = try decode(bytes)
        }
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<runs {
            let start = clock.now
            size = try decode(bytes)
            let elapsed = start.duration(to: clock.now).components
            times.append(Double(elapsed.seconds) * 1e3 + Double(elapsed.attoseconds) * 1e-15)
        }
        times.sort()
        let median =
            times.count % 2 == 1
            ? times[times.count / 2] : (times[times.count / 2 - 1] + times[times.count / 2]) / 2
        let name = URL(fileURLWithPath: path).lastPathComponent
        print(
            "{\"file\":\"\(name)\",\"width\":\(size.width),\"height\":\(size.height),"
                + "\"median_ms\":\(median),\"best_ms\":\(times[0]),\"runs\":\(runs)}"
        )
    }

    /// Hashes bytes with 64-bit FNV-1a, like the other measuring programs.
    public static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
