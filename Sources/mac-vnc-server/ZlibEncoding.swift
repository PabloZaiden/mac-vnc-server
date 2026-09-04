import Foundation
import zlib

final class ZlibEncoder {
    final class Transaction {
        private var stream = z_stream()
        private var initialized = false
        private var pendingOutput: [UInt8]
        private let compressionLevel: Int32

        fileprivate init(parent: ZlibEncoder) throws {
            pendingOutput = parent.pendingOutput
            compressionLevel = parent.compressionLevel

            let status = zlib.deflateCopy(&stream, &parent.stream)
            guard status == Z_OK else {
                throw RFBError.protocolError("zlib deflateCopy failed with status \(status)")
            }
            initialized = true
        }

        deinit {
            if initialized {
                zlib.deflateEnd(&stream)
            }
        }

        func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
            let raw = try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat)
            let compressed = try ZlibEncoder.deflate(
                raw,
                stream: &stream,
                pendingOutput: &pendingOutput
            )
            return UInt32(compressed.count).beBytes + compressed
        }

        fileprivate func copyState(
            to destination: UnsafeMutablePointer<z_stream>
        ) throws -> (pendingOutput: [UInt8], compressionLevel: Int32) {
            stream.next_in = nil
            stream.avail_in = 0
            stream.next_out = nil
            stream.avail_out = 0
            let status = zlib.deflateCopy(destination, &stream)
            guard status == Z_OK else {
                throw RFBError.protocolError("zlib deflateCopy failed with status \(status)")
            }
            return (pendingOutput, compressionLevel)
        }
    }

    private var stream = z_stream()
    private var initialized = false
    private var compressionLevel = Int32(Z_BEST_SPEED)
    private var pendingOutput: [UInt8] = []

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

    func setCompressionLevel(_ level: Int32) throws {
        guard (0...9).contains(Int(level)) else {
            throw RFBError.protocolError("invalid zlib compression level \(level)")
        }
        guard level != compressionLevel else {
            return
        }

        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        stream.next_in = nil
        stream.avail_in = 0

        repeat {
            let before = stream.total_out
            let chunkCount = chunk.count
            let status = chunk.withUnsafeMutableBytes { outputPointer in
                stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkCount)
                return zlib.deflateParams(&stream, level, Z_DEFAULT_STRATEGY)
            }

            guard status == Z_OK else {
                throw RFBError.protocolError("zlib deflateParams failed with status \(status)")
            }

            let produced = Int(stream.total_out - before)
            if produced > 0 {
                pendingOutput.append(contentsOf: chunk.prefix(produced))
            }
        } while stream.avail_out == 0

        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0
        compressionLevel = level
    }

    func beginTransaction() throws -> Transaction {
        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0
        return try Transaction(parent: self)
    }

    func commit(_ transaction: Transaction) throws {
        var oldStream = stream
        zlib.deflateEnd(&oldStream)
        stream = z_stream()
        initialized = false
        let metadata = try withUnsafeMutablePointer(to: &stream) { destination in
            try transaction.copyState(to: destination)
        }
        pendingOutput = metadata.pendingOutput
        compressionLevel = metadata.compressionLevel
        initialized = true
    }

    func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
        let raw = try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat)
        let compressed = try Self.deflate(raw, stream: &stream, pendingOutput: &pendingOutput)
        return UInt32(compressed.count).beBytes + compressed
    }

    private static func deflate(
        _ bytes: [UInt8],
        stream: inout z_stream,
        pendingOutput: inout [UInt8]
    ) throws -> [UInt8] {
        var output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        output.reserveCapacity(max(1024, bytes.count / 3))

        var input = bytes
        let inputCount = input.count
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        try input.withUnsafeMutableBytes { inputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(inputCount)

            repeat {
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
        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0

        return output
    }
}
