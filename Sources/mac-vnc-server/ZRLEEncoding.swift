import Foundation
import zlib

final class ZRLEEncoder {
    private var stream = z_stream()
    private var initialized = false

    init() throws {
        let status = deflateInit_(&stream, Z_BEST_SPEED, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw RFBError.protocolError("ZRLE deflateInit failed with status \(status)")
        }
        initialized = true
    }

    deinit {
        if initialized {
            deflateEnd(&stream)
        }
    }

    func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
        guard pixelFormat.trueColor, pixelFormat.bitsPerPixel == 32 else {
            throw RFBError.unsupportedPixelFormat(pixelFormat)
        }

        let uncompressed = Self.tileBytes(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat)
        let compressed = try deflate(uncompressed)
        return UInt32(compressed.count).beBytes + compressed
    }

    private func deflate(_ bytes: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(max(1024, bytes.count / 3))

        var input = bytes
        let inputCount = input.count
        try input.withUnsafeMutableBytes { inputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(inputCount)

            repeat {
                var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                let chunkCount = chunk.count
                let before = stream.total_out
                let status = chunk.withUnsafeMutableBytes { outputPointer in
                    stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkCount)
                    return zlib.deflate(&stream, Z_SYNC_FLUSH)
                }

                guard status == Z_OK else {
                    throw RFBError.protocolError("ZRLE deflate failed with status \(status)")
                }

                let produced = Int(stream.total_out - before)
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
            } while stream.avail_out == 0
        }

        return output
    }

    private static func tileBytes(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rect.width * rect.height * cPixelByteCount(for: pixelFormat))

        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileHeight = min(64, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileWidth = min(64, rect.x + rect.width - tileX)
                bytes.append(0)
                appendRawTile(
                    rect: Rect(x: tileX, y: tileY, width: tileWidth, height: tileHeight),
                    framebuffer: framebuffer,
                    pixelFormat: pixelFormat,
                    to: &bytes
                )
                tileX += 64
            }
            tileY += 64
        }

        return bytes
    }

    private static func appendRawTile(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat, to output: inout [UInt8]) {
        let cPixelBytes = cPixelByteCount(for: pixelFormat)
        for row in rect.y..<(rect.y + rect.height) {
            for column in rect.x..<(rect.x + rect.width) {
                let offset = row * framebuffer.bytesPerRow + column * 4
                let blue = framebuffer.bgra[offset]
                let green = framebuffer.bgra[offset + 1]
                let red = framebuffer.bgra[offset + 2]

                if pixelFormat.bigEndian {
                    if cPixelBytes == 4 {
                        output.append(0)
                    }
                    output.append(red)
                    output.append(green)
                    output.append(blue)
                } else {
                    output.append(blue)
                    output.append(green)
                    output.append(red)
                    if cPixelBytes == 4 {
                        output.append(0)
                    }
                }
            }
        }
    }

    private static func cPixelByteCount(for pixelFormat: PixelFormat) -> Int {
        if pixelFormat.bitsPerPixel == 32,
           pixelFormat.depth <= 24,
           pixelFormat.redMax <= 255,
           pixelFormat.greenMax <= 255,
           pixelFormat.blueMax <= 255,
           pixelFormat.redShift < 24,
           pixelFormat.greenShift < 24,
           pixelFormat.blueShift < 24 {
            return 3
        }
        return Int(pixelFormat.bitsPerPixel / 8)
    }
}
