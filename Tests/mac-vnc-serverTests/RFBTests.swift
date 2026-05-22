import CoreGraphics
import Testing
import zlib
@testable import mac_vnc_server

@Test func pixelFormatRoundTrip() throws {
    let format = PixelFormat.serverDefault
    #expect(try PixelFormat(bytes: format.bytes) == format)
}

@Test func rawEncodingUsesLittleEndianBGRForDefaultFormat() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x33, 0x22, 0x11, 0xff], layout: layout)
    let bytes = try RawEncoding.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )

    #expect(bytes == [0x33, 0x22, 0x11, 0x00])
}

@Test func incrementalRawEncodingReturnsChangedTilesOnly() {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let previous = Framebuffer(width: 2, height: 1, bgra: [
        0, 0, 0, 0,
        0, 0, 0, 0
    ], layout: layout)
    let current = Framebuffer(width: 2, height: 1, bgra: [
        0, 0, 0, 0,
        1, 0, 0, 0
    ], layout: layout)

    let rects = RawEncoding.rectangles(
        current: current,
        previous: previous,
        requested: Rect(x: 0, y: 0, width: 2, height: 1),
        incremental: true,
        tileSize: 1
    )

    #expect(rects == [Rect(x: 1, y: 0, width: 1, height: 1)])
}

@Test func zlibEncodingRoundTripsRawPayload() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let encoder = try ZlibEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    #expect(compressedLength == payload.count - 4)

    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 8)
    let decompressedCount = decompressed.count
    let status = compressed.withUnsafeMutableBytes { inputPointer in
        decompressed.withUnsafeMutableBytes { outputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressedLength)
            stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(decompressedCount)
            return inflate(&stream, Z_SYNC_FLUSH)
        }
    }

    #expect(status == Z_OK)
    #expect(decompressed == [0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00])
}

@Test func zrleEncodingUsesRawTilesWithCPixels() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let encoder = try ZRLEEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 7)
    let decompressedCount = decompressed.count
    let status = compressed.withUnsafeMutableBytes { inputPointer in
        decompressed.withUnsafeMutableBytes { outputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressedLength)
            stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(decompressedCount)
            return inflate(&stream, Z_SYNC_FLUSH)
        }
    }

    #expect(status == Z_OK)
    #expect(decompressed == [0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04])
}

@Test func zrleUsesFourByteCPixelsForDepth32Format() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x30, 0x20, 0x10, 0xff], layout: layout)
    let appleFormat = PixelFormat(
        bitsPerPixel: 32,
        depth: 32,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )
    let encoder = try ZRLEEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: appleFormat
    )

    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 5)
    let decompressedCount = decompressed.count
    let status = compressed.withUnsafeMutableBytes { inputPointer in
        decompressed.withUnsafeMutableBytes { outputPointer in
            stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressedLength)
            stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(decompressedCount)
            return inflate(&stream, Z_SYNC_FLUSH)
        }
    }

    #expect(status == Z_OK)
    #expect(decompressed == [0, 0x30, 0x20, 0x10, 0])
}

@Test func vncAuthKnownVector() throws {
    let challenge: [UInt8] = Array(0..<16)
    let response = try VNCAuth.response(challenge: challenge, password: "password")
    #expect(response == [0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb, 0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2])
}

@Test func virtualLayoutMapsNegativeCoordinates() {
    let display = VirtualDisplay(
        id: 1,
        bounds: CGRect(x: -100, y: 50, width: 200, height: 100),
        pixelWidth: 400,
        pixelHeight: 200
    )
    let layout = VirtualDisplayLayout(displays: [display])

    #expect(layout.width == 400)
    #expect(layout.height == 200)
    #expect(layout.globalPoint(framebufferX: 200, framebufferY: 100) == CGPoint(x: 0, y: 100))
}
