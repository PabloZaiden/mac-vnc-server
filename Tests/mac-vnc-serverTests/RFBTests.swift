import CoreGraphics
import Foundation
import Testing
import zlib
@testable import mac_vnc_server

@Test func cliParsesWakeupCommand() throws {
    let isWakeupCommand = if case .wakeup = try CLI.parse(arguments: ["wakeup"]) {
        true
    } else {
        false
    }

    #expect(isWakeupCommand)
}

@Test func cliParsesVerboseRunFlag() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--verbose"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.verbose)
}

@Test func clientCapabilitiesIdentifyStandardAndAppleFeatures() {
    let capabilities = RFBClientCapabilities(encodings: [
        RFBEncoding.raw.rawValue,
        RFBStandardEncoding.copyRect,
        RFBStandardEncoding.tight,
        RFBEncoding.zlib.rawValue,
        RFBEncoding.zrle.rawValue,
        RFBPseudoEncoding.richCursor,
        RFBPseudoEncoding.extendedDesktopSize,
        1011
    ])

    #expect(capabilities.supportsRaw)
    #expect(capabilities.supportsCopyRect)
    #expect(capabilities.supportsTight)
    #expect(capabilities.supportsZlib)
    #expect(capabilities.supportsZRLE)
    #expect(capabilities.supportsRichCursor)
    #expect(capabilities.supportsExtendedDesktopSize)
    #expect(capabilities.isAppleScreenSharingClient)
    #expect(capabilities.summary.contains("copyrect"))
    #expect(capabilities.summary.contains("apple=true"))
}

@Test func cliDisablesClipboardSyncByDefault() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(!config.clipboardSync)
}

@Test func cliDefaultsToAdaptiveFrameRate() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.fps == 60)
    #expect(config.adaptiveFrameRate)
}

@Test func cliUsesGeneratedPasswordConfigByDefault() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.password == nil)
    #expect(config.passwordFromConfig)
}

@Test func cliAcceptsExplicitPasswordOverride() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--password", "override"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.password == "override")
    #expect(!config.passwordFromConfig)
}

@Test func cliKeepsNoPasswordAsExplicitOverride() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--no-password"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.password == nil)
    #expect(!config.passwordFromConfig)
}

@Test func passwordStoreCreatesAndReusesEightBytePassword() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-vnc-server-password-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstPassword = try PasswordStore.loadOrCreate(in: directory)
    let secondPassword = try PasswordStore.loadOrCreate(in: directory)
    let fileURL = directory.appendingPathComponent(PasswordStore.configFileName)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)

    #expect(firstPassword == secondPassword)
    #expect(firstPassword.utf8.count == PasswordStore.passwordLength)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func passwordStoreRejectsSymlinkedPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-vnc-server-password-links-\(UUID().uuidString)", isDirectory: true)
    let fileManager = FileManager.default
    defer { try? fileManager.removeItem(at: root) }

    let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
    let linkedDirectory = root.appendingPathComponent("config-directory", isDirectory: true)
    try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: targetDirectory)

    var rejectedDirectoryLink = false
    do {
        _ = try PasswordStore.loadOrCreate(in: linkedDirectory)
    } catch {
        rejectedDirectoryLink = true
    }
    #expect(rejectedDirectoryLink)

    try fileManager.removeItem(at: linkedDirectory)
    let configURL = targetDirectory.appendingPathComponent(PasswordStore.configFileName)
    let targetURL = targetDirectory.appendingPathComponent("target.json")
    try Data(#"{"password":"ABCDEFGH"}"#.utf8).write(to: targetURL)
    try fileManager.createSymbolicLink(at: configURL, withDestinationURL: targetURL)

    var rejectedFileLink = false
    do {
        _ = try PasswordStore.loadOrCreate(in: targetDirectory)
    } catch {
        rejectedFileLink = true
    }
    #expect(rejectedFileLink)
}

@Test func cliParsesFixedFrameRate() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--fps", "30"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.fps == 30)
    #expect(!config.adaptiveFrameRate)
}

@Test func cliParsesAutoFrameRate() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--fps", "auto"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.fps == 60)
    #expect(config.adaptiveFrameRate)
}

@Test func adaptiveFrameRateUses60To45To30WithHysteresis() {
    var controller = AdaptiveFrameRateController()

    for _ in 0..<5 {
        #expect(controller.update(frameDuration: 0.020) == nil)
    }
    #expect(controller.update(frameDuration: 0.020) == 45)
    #expect(controller.frameRate == 45)

    for index in 0..<6 {
        #expect(controller.update(frameDuration: 0.030) == (index == 5 ? 30 : nil))
    }
    #expect(controller.frameRate == 30)

    for _ in 0..<89 {
        #expect(controller.update(frameDuration: 0.010) == nil)
    }
    #expect(controller.update(frameDuration: 0.010) == 45)
    #expect(controller.update(frameDuration: 0.010) == nil)
    #expect(controller.frameRate == 45)
}

@Test func cliParsesClipboardSyncFlag() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--clipboard-sync"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(config.clipboardSync)
}

@Test func cliDisablesAdaptiveStreamingWhenRequested() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["run", "--no-adaptive"]) else {
        Issue.record("expected run command")
        return
    }

    #expect(!config.adaptiveStreaming)
    #expect(!config.adaptiveFrameRate)
}

@Test func cliParsesUpdateCommand() throws {
    guard case .update = try CLI.parse(arguments: ["update"]) else {
        Issue.record("expected update command")
        return
    }
}

@Test func semanticVersionsTreatDevelopmentBuildAsOlderThanRelease() {
    guard let development = SemanticVersion("0.0.0-development"),
          let release = SemanticVersion("v0.2.5"),
          let olderRelease = SemanticVersion("0.2.4"),
          let sameRelease = SemanticVersion("0.2.5") else {
        Issue.record("expected valid semantic versions")
        return
    }

    #expect(development < release)
    #expect(olderRelease < release)
    #expect(release == sameRelease)
}

@Test func noDisplaysErrorSuggestsWakeupCommand() {
    let message = CLI.errorMessage(for: RFBError.captureFailed("ScreenCaptureKit found no displays"))

    #expect(message.contains("mac-vnc-server wakeup"))
}

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

@Test func rawEncodingHonorsClientRequestedColorShifts() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x33, 0x22, 0x11, 0xff], layout: layout)
    let noVNCFormat = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 0,
        greenShift: 8,
        blueShift: 16
    )
    let bytes = try RawEncoding.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: noVNCFormat
    )

    #expect(bytes == [0x11, 0x22, 0x33, 0x00])
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

@Test func incrementalRawEncodingCoalescesAdjacentChangedTiles() {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 2)
    let previous = Framebuffer(
        width: 2,
        height: 2,
        bgra: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        layout: layout
    )
    let current = Framebuffer(
        width: 2,
        height: 2,
        bgra: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
        layout: layout
    )

    let rects = RawEncoding.rectangles(
        current: current,
        previous: previous,
        requested: Rect(x: 0, y: 0, width: 2, height: 2),
        incremental: true,
        tileSize: 1
    )

    #expect(rects == [Rect(x: 0, y: 0, width: 2, height: 2)])
}

@Test func incrementalRawEncodingUsesDirtyRectsToSkipCleanTiles() {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 4, height: 1)
    let previous = Framebuffer(
        width: 4,
        height: 1,
        bgra: [UInt8](repeating: 0, count: 16),
        layout: layout
    )
    var currentBytes = [UInt8](repeating: 0, count: 16)
    currentBytes[0] = 1
    currentBytes[12] = 1
    let current = Framebuffer(width: 4, height: 1, bgra: currentBytes, layout: layout)

    let rects = RawEncoding.rectangles(
        current: current,
        previous: previous,
        requested: Rect(x: 0, y: 0, width: 4, height: 1),
        incremental: true,
        dirtyRects: [Rect(x: 3, y: 0, width: 1, height: 1)],
        tileSize: 1
    )

    #expect(rects == [Rect(x: 3, y: 0, width: 1, height: 1)])
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

@Test func zlibCompressionLevelCanChangeBetweenUpdates() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let encoder = try ZlibEncoder()
    let first = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )
    try encoder.setCompressionLevel(6)
    let second = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 2, height: 1),
        framebuffer: framebuffer,
        pixelFormat: .serverDefault
    )

    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var decompressed = [UInt8]()
    for payload in [first, second] {
        let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
        var compressed = Array(payload.dropFirst(4))
        var output = [UInt8](repeating: 0, count: 8)
        let outputCount = output.count
        let status = compressed.withUnsafeMutableBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(compressedLength)
                stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }

        #expect(status == Z_OK)
        decompressed += output.prefix(8 - Int(stream.avail_out))
    }

    #expect(decompressed == [
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00,
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00
    ])
}

@Test func discardedZlibTransactionDoesNotAdvanceStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZlibEncoder()

    do {
        let transaction = try encoder.beginTransaction()
        _ = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    }

    let payload = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    #expect(try inflatePayloads([payload], outputCounts: [8]) == [
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00
    ])
}

@Test func committedZlibTransactionContinuesStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZlibEncoder()
    let transaction = try encoder.beginTransaction()
    let first = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    try encoder.commit(transaction)
    let second = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)

    #expect(try inflatePayloads([first, second], outputCounts: [8, 8]) == [
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00,
        0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00
    ])
}

@Test func discardedZRLETransactionDoesNotAdvanceStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZRLEEncoder()

    do {
        let transaction = try encoder.beginTransaction()
        _ = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    }

    let payload = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    #expect(try inflatePayloads([payload], outputCounts: [7]) == [
        0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04
    ])
}

@Test func committedZRLETransactionContinuesStream() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1)
    let framebuffer = Framebuffer(width: 2, height: 1, bgra: [
        0x03, 0x02, 0x01, 0xff,
        0x06, 0x05, 0x04, 0xff
    ], layout: layout)
    let rect = Rect(x: 0, y: 0, width: 2, height: 1)
    let encoder = try ZRLEEncoder()
    let transaction = try encoder.beginTransaction()
    let first = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)
    try encoder.commit(transaction)
    let second = try encoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: .serverDefault)

    #expect(try inflatePayloads([first, second], outputCounts: [7, 7]) == [
        0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04,
        0, 0x03, 0x02, 0x01, 0x06, 0x05, 0x04
    ])
}

@Test func clientSocketWriteTimesOutWithoutPeerProgress() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        Issue.record("socketpair failed: \(String(cString: strerror(errno)))")
        return
    }
    defer { close(descriptors[1]) }

    var sendBufferSize: Int32 = 4 * 1024
    setsockopt(
        descriptors[0],
        SOL_SOCKET,
        SO_SNDBUF,
        &sendBufferSize,
        socklen_t(MemoryLayout<Int32>.size)
    )

    let socket = try ClientSocket(fd: descriptors[0])
    let payload = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
    var didTimeout = false
    do {
        try socket.writeAll(payload, idleTimeout: 0.05)
    } catch {
        didTimeout = true
    }

    #expect(didTimeout)
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

@Test func zrleEncodingHonorsClientRequestedColorShifts() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
    let framebuffer = Framebuffer(width: 1, height: 1, bgra: [0x30, 0x20, 0x10, 0xff], layout: layout)
    let noVNCFormat = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 0,
        greenShift: 8,
        blueShift: 16
    )
    let encoder = try ZRLEEncoder()
    let payload = try encoder.encode(
        rect: Rect(x: 0, y: 0, width: 1, height: 1),
        framebuffer: framebuffer,
        pixelFormat: noVNCFormat
    )

    let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
    var stream = z_stream()
    #expect(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }

    var compressed = Array(payload.dropFirst(4))
    var decompressed = [UInt8](repeating: 0, count: 4)
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
    #expect(decompressed == [0, 0x10, 0x20, 0x30])
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

private func inflatePayloads(_ payloads: [[UInt8]], outputCounts: [Int]) throws -> [UInt8] {
    guard payloads.count == outputCounts.count else {
        throw RFBError.protocolError("test payload count mismatch")
    }

    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw RFBError.protocolError("test inflateInit failed")
    }
    defer { inflateEnd(&stream) }

    var result: [UInt8] = []
    for (payload, outputCount) in zip(payloads, outputCounts) {
        guard payload.count >= 4 else {
            throw RFBError.protocolError("test payload is missing its length")
        }
        let compressedLength = Int(UInt32.be(payload[0], payload[1], payload[2], payload[3]))
        var compressed = Array(payload.dropFirst(4))
        var output = [UInt8](repeating: 0, count: outputCount)
        let status = compressed.withUnsafeMutableBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                stream.next_in = inputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(compressedLength)
                stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard status == Z_OK else {
            throw RFBError.protocolError("test inflate failed with status \(status)")
        }
        result += output.prefix(outputCount - Int(stream.avail_out))
    }
    return result
}
