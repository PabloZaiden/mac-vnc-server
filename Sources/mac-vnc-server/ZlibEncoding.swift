import Foundation
import zlib

final class ZlibEncoder {
    private var stream = z_stream()
    private var initialized = false

    init() throws {
        let status = deflateInit_(&stream, Z_BEST_SPEED, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw RFBError.protocolError("zlib deflateInit failed with status \(status)")
        }
        initialized = true
    }

    deinit {
        if initialized {
            deflateEnd(&stream)
        }
    }

    func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
        let raw = try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat)
        let compressed = try deflate(raw)
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
                    throw RFBError.protocolError("zlib deflate failed with status \(status)")
                }

                let produced = Int(stream.total_out - before)
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
            } while stream.avail_out == 0
        }

        return output
    }
}
