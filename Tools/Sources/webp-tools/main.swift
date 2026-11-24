import Foundation

// Maintainer tools that use the libwebp command-line programs as a reference.

let usage = """
    usage: webp-tools fixtures <output-directory>
           webp-tools decoder-fixtures <output-directory>
           webp-tools animation-fixtures <output-directory>
           webp-tools golden <corpus-directory> <output-file>
           webp-tools animation-golden <fixture-directory> <output-file>
           webp-tools speed <file>...
           webp-tools animation-speed <file>...
           webp-tools differential <iterations> [seed]
           webp-tools animation-differential <iterations> [seed]
    """

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch (arguments.first, arguments.count) {
    case ("fixtures", 2):
        try generateFixtures(in: URL(fileURLWithPath: arguments[1]))
    case ("decoder-fixtures", 2):
        try generateDecoderFixtures(in: URL(fileURLWithPath: arguments[1]))
    case ("animation-fixtures", 2):
        try generateAnimationFixtures(in: URL(fileURLWithPath: arguments[1]))
    case ("animation-golden", 3):
        try generateAnimationGolden(
            fixtures: URL(fileURLWithPath: arguments[1]),
            output: URL(fileURLWithPath: arguments[2])
        )
    case ("golden", 3):
        try generateGolden(
            corpus: URL(fileURLWithPath: arguments[1]),
            output: URL(fileURLWithPath: arguments[2])
        )
    case ("animation-speed", 2...):
        try measureAnimationSpeed(files: arguments.dropFirst().map { URL(fileURLWithPath: $0) })
    case ("speed", 2...):
        try measureSpeed(files: arguments.dropFirst().map { URL(fileURLWithPath: $0) })
    case ("differential", 2...3):
        guard let iterations = Int(arguments[1]) else {
            throw ToolFailure(description: usage)
        }
        let seed = arguments.count == 3 ? UInt64(arguments[2]) : nil
        try runDifferentialTest(iterations: iterations, seed: seed ?? 1)
    case ("animation-differential", 2...3):
        guard let iterations = Int(arguments[1]) else {
            throw ToolFailure(description: usage)
        }
        let seed = arguments.count == 3 ? UInt64(arguments[2]) : nil
        try runAnimationDifferentialTest(iterations: iterations, seed: seed ?? 1)
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
