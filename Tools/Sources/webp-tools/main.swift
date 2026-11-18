import Foundation

// Maintainer tools that use the libwebp command-line programs as a reference.
//
//   webp-tools fixtures <output-directory>
//   webp-tools golden <corpus-directory> <output-file>

let arguments = CommandLine.arguments.dropFirst()

do {
    switch (arguments.first, arguments.count) {
    case ("fixtures", 2):
        try generateFixtures(in: URL(fileURLWithPath: arguments[2]))
    case ("golden", 3):
        try generateGolden(
            corpus: URL(fileURLWithPath: arguments[2]),
            output: URL(fileURLWithPath: arguments[3])
        )
    default:
        print("usage: webp-tools fixtures <output-directory>")
        print("       webp-tools golden <corpus-directory> <output-file>")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
