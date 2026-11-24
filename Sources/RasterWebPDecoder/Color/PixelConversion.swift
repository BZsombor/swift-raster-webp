/// Converts decoded ARGB pixels into their output representation.
enum PixelConversion {
    /// Multiplies the color channels of each pixel by its alpha value.
    static func premultiply(_ pixels: inout MutableSpan<UInt32>, count: Int) {
        var index = 0
        while index < count {
            let pixel = pixels[index]
            if pixel &>> 24 != 255 {
                pixels[index] = premultiplied(pixel)
            }
            index &+= 1
        }
    }

    /// Returns a pixel with its color channels multiplied by its alpha value.
    @inline(always)
    static func premultiplied(_ pixel: UInt32) -> UInt32 {
        let alpha = pixel &>> 24
        let red = multiply((pixel &>> 16) & 0xFF, by: alpha)
        let green = multiply((pixel &>> 8) & 0xFF, by: alpha)
        let blue = multiply(pixel & 0xFF, by: alpha)
        return alpha &<< 24 | red &<< 16 | green &<< 8 | blue
    }

    /// Returns `value * alpha / 255`, rounded to the nearest integer.
    @inline(always)
    static func multiply(_ value: UInt32, by alpha: UInt32) -> UInt32 {
        let product = value &* alpha &+ 128
        return (product &+ (product &>> 8)) &>> 8
    }

    /// Stores each pixel so that its bytes are in blue, green, red, alpha order.
    static func storeBGRA(_ pixels: inout MutableSpan<UInt32>, count: Int) {
        #if _endian(big)
            var index = 0
            while index < count {
                pixels[index] = pixels[index].byteSwapped
                index &+= 1
            }
        #endif
    }

    /// Stores each pixel so that its bytes are in red, green, blue, alpha order.
    static func storeRGBA(_ pixels: inout MutableSpan<UInt32>, count: Int) {
        var index = 0
        while index < count {
            let pixel = pixels[index]
            let swapped = (pixel & 0xFF00_FF00) | (pixel & 0xFF) &<< 16 | (pixel &>> 16) & 0xFF
            pixels[index] = swapped.littleEndian
            index &+= 1
        }
    }

    /// Copies pixels from four-byte BGRA rows to three-byte rows, moving forward through memory.
    ///
    /// The source and destination may start at the same address.
    static func packThreeByteRows(
        in bytes: inout MutableSpan<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        swapRedAndBlue: Bool
    ) {
        let firstChannel = swapRedAndBlue ? 2 : 0
        let lastChannel = swapRedAndBlue ? 0 : 2
        var source = 0
        var row = 0
        while row < height {
            var destination = row &* bytesPerRow
            var column = 0
            while column < width {
                let first = bytes[source &+ firstChannel]
                let middle = bytes[source &+ 1]
                let last = bytes[source &+ lastChannel]
                bytes[destination] = first
                bytes[destination &+ 1] = middle
                bytes[destination &+ 2] = last
                source &+= 4
                destination &+= 3
                column &+= 1
            }
            row &+= 1
        }
    }

    /// Writes ARGB pixels into rows of any output format, at any distance between rows.
    static func writeRows(
        of pixels: Span<UInt32>,
        width: Int,
        height: Int,
        into output: inout MutableSpan<UInt8>,
        bytesPerRow: Int,
        options: WebPDecodingOptions
    ) {
        let premultiplies = options.alphaMode == .premultiplied
        let layout = options.pixelFormat.layout
        let swapsRedAndBlue = layout == .bgra || layout == .bgr
        let hasAlpha = options.pixelFormat.bytesPerPixel == 4
        var source = 0
        var row = 0
        while row < height {
            var destination = row &* bytesPerRow
            var column = 0
            while column < width {
                var pixel = pixels[source]
                if premultiplies, pixel &>> 24 != 255 {
                    pixel = premultiplied(pixel)
                }
                let red = UInt8(truncatingIfNeeded: pixel &>> 16)
                let blue = UInt8(truncatingIfNeeded: pixel)
                output[destination] = swapsRedAndBlue ? blue : red
                output[destination &+ 1] = UInt8(truncatingIfNeeded: pixel &>> 8)
                output[destination &+ 2] = swapsRedAndBlue ? red : blue
                if hasAlpha {
                    output[destination &+ 3] = UInt8(truncatingIfNeeded: pixel &>> 24)
                    destination &+= 4
                } else {
                    destination &+= 3
                }
                source &+= 1
                column &+= 1
            }
            row &+= 1
        }
    }
}
