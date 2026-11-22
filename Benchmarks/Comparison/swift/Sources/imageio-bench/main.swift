#if canImport(ImageIO)
    import BenchSupport
    import CoreGraphics
    import Foundation
    import ImageIO

    /// Decodes with Apple's ImageIO into its own 8-bit pixel buffer.
    func decodedImage(_ bytes: [UInt8]) throws -> CGImage {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    Bench.main(
        decode: { bytes in
            let image = try decodedImage(bytes)
            // Reading the pixel data makes sure that the decoding is not deferred.
            guard let data = image.dataProvider?.data, CFDataGetLength(data) > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (image.width, image.height)
        },
        rgba: { bytes in
            // Core Graphics only draws premultiplied RGBA, so straight alpha is computed back.
            let image = try decodedImage(bytes)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress,
                        width: image.width,
                        height: image.height,
                        bitsPerComponent: 8,
                        bytesPerRow: image.width * 4,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    )
                else {
                    return false
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[index + 3])
                if alpha > 0, alpha < 255 {
                    for channel in index..<(index + 3) {
                        let straight = (Int(pixels[channel]) * 255 + alpha / 2) / alpha
                        pixels[channel] = UInt8(min(255, straight))
                    }
                }
            }
            return pixels
        }
    )
#else
    print("ImageIO is only available on Apple platforms")
#endif
