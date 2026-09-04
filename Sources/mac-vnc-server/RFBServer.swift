import Foundation
import zlib

struct ServerConfig {
    let bindAddress: String
    let port: UInt16
    let password: String?
    let fps: Int
    let scale: Double
    let encodingPreference: EncodingPreference
    let displaySelection: DisplaySelection
    let verbose: Bool
    let clipboardSync: Bool
    let adaptiveStreaming: Bool
}

enum DisplaySelection: Equatable {
    case automatic
    case all
    case display(Int)
}

enum EncodingPreference: String {
    case auto
    case zrle
    case zlib
    case raw
}

enum RFBEncoding: Int32 {
    case raw = 0
    case zlib = 6
    case zrle = 16
}

final class RFBServer {
    private let config: ServerConfig
    private let capture: FramebufferSource
    private let input: InputController
    private let clipboard: ClipboardBridge
    private let logger: ServerLogger

    init(
        config: ServerConfig,
        capture: FramebufferSource,
        input: InputController,
        clipboard: ClipboardBridge,
        logger: ServerLogger
    ) {
        self.config = config
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
        self.logger = logger
    }

    func run() throws {
        let listener = try ListeningSocket(bindAddress: config.bindAddress, port: config.port)
        logger.info("mac-vnc-server \(AppVersion.current)")
        logger.info("mac-vnc-server listening on \(config.bindAddress):\(config.port)")
        logger.info("fps=\(config.fps) scale=\(config.scale) encoding=\(config.encodingPreference.rawValue) display=\(config.displaySelection.description)")
        logger.info("password configured: \(config.password != nil)")
        logger.info("clipboard sync: \(config.clipboardSync ? "enabled" : "disabled")")
        logger.info("Connect with vnc://\(config.bindAddress == "0.0.0.0" ? "127.0.0.1" : config.bindAddress):\(config.port)")

        while true {
            let client = try listener.acceptClient()
            do {
                try RFBClientSession(
                    socket: client,
                    password: config.password,
                    fps: config.fps,
                    encodingPreference: config.encodingPreference,
                    capture: capture,
                    input: input,
                    clipboard: clipboard,
                    clipboardSync: config.clipboardSync,
                    adaptiveStreaming: config.adaptiveStreaming,
                    logger: logger
                ).run()
            } catch {
                logger.warning("client disconnected: \(error.localizedDescription)")
            }
        }
    }
}

extension DisplaySelection {
    var description: String {
        switch self {
        case .automatic:
            return "auto"
        case .all:
            return "all"
        case .display(let index):
            return "\(index)"
        }
    }
}

final class RFBClientSession: @unchecked Sendable {
    private struct FramebufferUpdateRequest {
        let incremental: Bool
        let rect: Rect
    }

    private let socket: ClientSocket
    private let password: String?
    private let minimumFrameInterval: TimeInterval
    private var frameInterval: TimeInterval
    private let encodingPreference: EncodingPreference
    private let capture: FramebufferSource
    private let input: InputController
    private let clipboard: ClipboardBridge
    private let clipboardSync: Bool
    private let adaptiveStreaming: Bool
    private let logger: ServerLogger
    private var pixelFormat = PixelFormat.serverDefault
    private var clientEncodings: [Int32] = [RFBEncoding.raw.rawValue]
    private var isAppleScreenSharingClient = false
    private var previousFramebuffer: Framebuffer?
    private var currentLayout = VirtualDisplayLayout.empty
    private var lastFramebufferUpdate = Date.distantPast
    private var hasSentFramebufferUpdate = false
    private let zrleEncoder: ZRLEEncoder
    private let zlibEncoder: ZlibEncoder
    private let state = NSCondition()
    private var stopped = false
    private var latestUpdateRequest: FramebufferUpdateRequest?
    private var activeUpdateRequest: FramebufferUpdateRequest?
    private var writerError: Error?
    private var updatesSent = 0
    private var bytesSent = 0
    private var fastUpdateCount = 0

    init(
        socket: ClientSocket,
        password: String?,
        fps: Int,
        encodingPreference: EncodingPreference,
        capture: FramebufferSource,
        input: InputController,
        clipboard: ClipboardBridge,
        clipboardSync: Bool,
        adaptiveStreaming: Bool,
        logger: ServerLogger
    ) throws {
        self.socket = socket
        self.password = password
        minimumFrameInterval = 1.0 / Double(fps)
        frameInterval = minimumFrameInterval
        self.encodingPreference = encodingPreference
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
        self.clipboardSync = clipboardSync
        self.adaptiveStreaming = adaptiveStreaming
        self.logger = logger
        zrleEncoder = try ZRLEEncoder()
        zlibEncoder = try ZlibEncoder()
    }

    func run() throws {
        let initialFrame = try capture.capture()
        currentLayout = initialFrame.layout
        previousFramebuffer = initialFrame

        try handshake(initialFrame: initialFrame)
        startFramebufferWriter()
        defer { stopFramebufferWriter() }

        while true {
            if let writerError = consumeWriterError() {
                throw writerError
            }
            let messageType = try socket.readExact(1)[0]
            switch messageType {
            case 0:
                try handleSetPixelFormat()
            case 2:
                try handleSetEncodings()
            case 3:
                try handleFramebufferUpdateRequestMessage()
            case 4:
                try handleKeyEvent()
            case 5:
                try handlePointerEvent()
            case 6:
                try handleClientCutText()
            default:
                throw RFBError.protocolError("unsupported client message \(messageType)")
            }
        }
    }

    private func handshake(initialFrame: Framebuffer) throws {
        let preferLegacyHandshake = password != nil
        try socket.writeString(preferLegacyHandshake ? "RFB 003.003\n" : "RFB 003.008\n")
        let clientVersion = try socket.readExact(12)
        let versionText = String(bytes: clientVersion, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let isRFB33 = preferLegacyHandshake || versionText == "RFB 003.003"

        if isRFB33 {
            if let password {
                try socket.writeAll(UInt32(2).beBytes)
                try authenticate(password: password)
            } else {
                try socket.writeAll(UInt32(1).beBytes)
            }
        } else {
            if password == nil {
                try socket.writeAll([1, 1])
            } else {
                try socket.writeAll([2, 2, 1])
            }

            let selectedSecurity = try socket.readExact(1)[0]
            switch selectedSecurity {
            case 1:
                try socket.writeAll(UInt32(0).beBytes)
            case 2:
                guard let password else {
                    try socket.writeAll(UInt32(1).beBytes)
                    throw RFBError.authenticationFailed
                }
                try authenticate(password: password)
            default:
                throw RFBError.protocolError("unsupported security type \(selectedSecurity)")
            }
        }

        _ = try socket.readExact(1)
        try sendServerInit(framebuffer: initialFrame)
        logger.info("client connected: \(versionText), framebuffer \(initialFrame.width)x\(initialFrame.height)")
    }

    private func authenticate(password: String) throws {
        var challenge = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, challenge.count, &challenge)
        if status != errSecSuccess {
            for index in challenge.indices {
                challenge[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }

        try socket.writeAll(challenge)
        let response = try socket.readExact(16)
        if try VNCAuth.response(challenge: challenge, password: password) == response {
            try socket.writeAll(UInt32(0).beBytes)
        } else {
            try socket.writeAll(UInt32(1).beBytes)
            throw RFBError.authenticationFailed
        }
    }

    private func sendServerInit(framebuffer: Framebuffer) throws {
        var bytes: [UInt8] = []
        bytes += UInt16(framebuffer.width).beBytes
        bytes += UInt16(framebuffer.height).beBytes
        bytes += PixelFormat.serverDefault.bytes
        let name = "mac-vnc-server".data(using: .utf8) ?? Data()
        bytes += UInt32(name.count).beBytes
        bytes += Array(name)
        try socket.writeAll(bytes)
    }

    private func handleSetPixelFormat() throws {
        _ = try socket.readExact(3)
        let bytes = try socket.readExact(16)
        let requested = try PixelFormat(bytes: bytes)
        guard requested.trueColor, [8, 16, 32].contains(requested.bitsPerPixel) else {
            throw RFBError.unsupportedPixelFormat(requested)
        }
        state.lock()
        pixelFormat = requested
        state.unlock()
    }

    private func handleSetEncodings() throws {
        _ = try socket.readExact(1)
        let countBytes = try socket.readExact(2)
        let count = Int(UInt16.be(countBytes[0], countBytes[1]))
        let bytes = try socket.readExact(count * 4)
        let encodings = stride(from: 0, to: bytes.count, by: 4).map { offset in
            Int32(bitPattern: UInt32.be(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]))
        }
        state.lock()
        clientEncodings = encodings
        isAppleScreenSharingClient = encodings.contains(1011)
            || encodings.contains(1002)
            || encodings.contains(1100)
            || encodings.contains(1104)
        state.unlock()
    }

    private func handleFramebufferUpdateRequestMessage() throws {
        let header = try socket.readExact(9)
        let incremental = header[0] != 0
        let x = Int(UInt16.be(header[1], header[2]))
        let y = Int(UInt16.be(header[3], header[4]))
        let width = Int(UInt16.be(header[5], header[6]))
        let height = Int(UInt16.be(header[7], header[8]))

        state.lock()
        latestUpdateRequest = FramebufferUpdateRequest(
            incremental: incremental,
            rect: Rect(x: x, y: y, width: width, height: height)
        )
        state.signal()
        state.unlock()
    }

    private func startFramebufferWriter() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            do {
                try framebufferWriterLoop()
            } catch {
                state.lock()
                writerError = error
                stopped = true
                state.broadcast()
                state.unlock()
            }
        }
    }

    private func framebufferWriterLoop() throws {
        while true {
            let request = waitForUpdateRequest()
            guard let request else {
                return
            }
            try sendFramebufferUpdate(request)
        }
    }

    private func waitForUpdateRequest() -> FramebufferUpdateRequest? {
        state.lock()
        defer { state.unlock() }

        while latestUpdateRequest == nil && activeUpdateRequest == nil && !stopped {
            state.wait()
        }
        guard !stopped else {
            return nil
        }

        if let request = latestUpdateRequest {
            latestUpdateRequest = nil
            activeUpdateRequest = request
            return request
        }

        guard let activeUpdateRequest else {
            return nil
        }

        return FramebufferUpdateRequest(
            incremental: true,
            rect: activeUpdateRequest.rect
        )
    }

    private func stopFramebufferWriter() {
        state.lock()
        stopped = true
        state.broadcast()
        state.unlock()
    }

    private func sendFramebufferUpdate(_ request: FramebufferUpdateRequest) throws {
        throttleFrameRate()
        let frameStarted = Date()

        let framebuffer = try capture.capture()
        let requested = request.rect
        let (format, encoding, previous, sentBefore) = stateSnapshotForEncoding()
        let shouldDiff = sentBefore
            && request.incremental
        let dirtyRects: [Rect]?
        if shouldDiff,
           let previous,
           let sequence = framebuffer.sequence,
           let previousSequence = previous.sequence,
           sequence == previousSequence &+ 1 {
            dirtyRects = framebuffer.dirtyRects
        } else {
            dirtyRects = nil
        }
        let rects: [Rect]
        if shouldDiff,
           let previous,
           let sequence = framebuffer.sequence,
           previous.sequence == sequence {
            rects = []
        } else {
            rects = RawEncoding.rectangles(
                current: framebuffer,
                previous: previous,
                requested: requested,
                incremental: shouldDiff,
                dirtyRects: dirtyRects
            )
        }

        let header = [0, 0] + UInt16(rects.count).beBytes
        try socket.writeAll(header)
        var updateBytes = header.count

        for rect in rects {
            let payload: [UInt8]
            let encodingBytes = UInt32(bitPattern: encoding.rawValue).beBytes
            switch encoding {
            case .zrle:
                payload = try zrleEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            case .zlib:
                payload = try zlibEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            case .raw:
                payload = try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            }

            var rectResponse: [UInt8] = []
            rectResponse.reserveCapacity(12 + payload.count)
            rectResponse += UInt16(rect.x).beBytes
            rectResponse += UInt16(rect.y).beBytes
            rectResponse += UInt16(rect.width).beBytes
            rectResponse += UInt16(rect.height).beBytes
            rectResponse += encodingBytes
            rectResponse += payload
            try socket.writeAll(rectResponse)
            updateBytes += rectResponse.count
        }

        state.lock()
        updatesSent += 1
        bytesSent += updateBytes
        if updatesSent == 1 || updatesSent % 60 == 0 {
            logger.verbose("updates=\(updatesSent) encoding=\(encoding) last_rects=\(rects.count) total_bytes=\(bytesSent)")
        }
        previousFramebuffer = framebuffer
        currentLayout = framebuffer.layout
        hasSentFramebufferUpdate = true
        state.unlock()

        try adaptStreaming(frameDuration: Date().timeIntervalSince(frameStarted), encoding: encoding)

        if clipboardSync, let text = clipboard.localTextIfChanged() {
            try sendServerCutText(text)
        }
    }

    private func stateSnapshotForEncoding() -> (PixelFormat, RFBEncoding, Framebuffer?, Bool) {
        state.lock()
        defer { state.unlock() }
        return (pixelFormat, selectedEncodingLocked(), previousFramebuffer, hasSentFramebufferUpdate)
    }

    private func consumeWriterError() -> Error? {
        state.lock()
        defer { state.unlock() }
        let error = writerError
        writerError = nil
        return error
    }

    private func selectedEncoding() -> RFBEncoding {
        state.lock()
        defer { state.unlock() }
        return selectedEncodingLocked()
    }

    private func selectedEncodingLocked() -> RFBEncoding {
        switch encodingPreference {
        case .raw:
            return .raw
        case .zrle:
            return clientEncodings.contains(RFBEncoding.zrle.rawValue) ? .zrle : .raw
        case .zlib:
            return clientEncodings.contains(RFBEncoding.zlib.rawValue) ? .zlib : .raw
        case .auto:
            if isAppleScreenSharingClient, clientEncodings.contains(RFBEncoding.zlib.rawValue) {
                return .zlib
            }
            if clientEncodings.contains(RFBEncoding.zrle.rawValue) {
                return .zrle
            }
            return clientEncodings.contains(RFBEncoding.zlib.rawValue) ? .zlib : .raw
        }
    }

    private func throttleFrameRate() {
        let elapsed = Date().timeIntervalSince(lastFramebufferUpdate)
        if elapsed < frameInterval {
            usleep(useconds_t((frameInterval - elapsed) * 1_000_000))
        }
        lastFramebufferUpdate = Date()
    }

    private func adaptStreaming(frameDuration: TimeInterval, encoding: RFBEncoding) throws {
        guard adaptiveStreaming else {
            return
        }

        let target = minimumFrameInterval
        if frameDuration > target * 1.25 {
            frameInterval = min(0.5, max(target, frameDuration * 1.1))
            fastUpdateCount = 0

            let level: Int32 = frameDuration > target * 2.5 ? 6 : 3
            try setCompressionLevel(level, for: encoding)
            return
        }

        guard frameDuration < target * 0.75 else {
            fastUpdateCount = 0
            return
        }

        fastUpdateCount += 1
        guard fastUpdateCount >= 30 else {
            return
        }

        fastUpdateCount = 0
        frameInterval = max(target, frameInterval * 0.9)
        if frameInterval <= target * 1.05 {
            try setCompressionLevel(1, for: encoding)
        }
    }

    private func setCompressionLevel(_ level: Int32, for encoding: RFBEncoding) throws {
        switch encoding {
        case .zrle:
            try zrleEncoder.setCompressionLevel(level)
        case .zlib:
            try zlibEncoder.setCompressionLevel(level)
        case .raw:
            return
        }
    }

    private func handleKeyEvent() throws {
        let bytes = try socket.readExact(7)
        let down = bytes[0] != 0
        let keysym = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
        state.lock()
        let mapAltToCommand = isAppleScreenSharingClient
        state.unlock()
        requestCaptureRecoveryAfterInput()
        input.key(down: down, keysym: keysym, mapAltToCommand: mapAltToCommand)
    }

    private func handlePointerEvent() throws {
        let bytes = try socket.readExact(5)
        let mask = bytes[0]
        let x = UInt16.be(bytes[1], bytes[2])
        let y = UInt16.be(bytes[3], bytes[4])
        state.lock()
        let layout = currentLayout
        state.unlock()
        requestCaptureRecoveryAfterInput()
        input.pointer(buttonMask: mask, x: x, y: y, layout: layout)
    }

    private func requestCaptureRecoveryAfterInput() {
        (capture as? InputRecoverySource)?.requestRecoveryAfterInput()
    }

    private func handleClientCutText() throws {
        _ = try socket.readExact(3)
        let lengthBytes = try socket.readExact(4)
        let length = Int(UInt32.be(lengthBytes[0], lengthBytes[1], lengthBytes[2], lengthBytes[3]))
        let bytes = try socket.readExact(length)
        if clipboardSync {
            let text = String(decoding: bytes, as: UTF8.self)
            clipboard.setRemoteText(text)
        }
    }

    private func sendServerCutText(_ text: String) throws {
        let payload = Array(text.utf8)
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += UInt32(payload.count).beBytes
        bytes += payload
        try socket.writeAll(bytes)
    }
}
