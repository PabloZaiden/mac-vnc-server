import Foundation

struct ServerConfig {
    let bindAddress: String
    let port: UInt16
    let password: String?
    let fps: Int
    let scale: Double
    let encodingPreference: EncodingPreference
    let displaySelection: DisplaySelection
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

    init(config: ServerConfig, capture: FramebufferSource, input: InputController, clipboard: ClipboardBridge) {
        self.config = config
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
    }

    func run() throws {
        let listener = try ListeningSocket(bindAddress: config.bindAddress, port: config.port)
        print("mac-vnc-server \(AppVersion.current)")
        print("mac-vnc-server listening on \(config.bindAddress):\(config.port)")
        print("fps=\(config.fps) scale=\(config.scale) encoding=\(config.encodingPreference.rawValue) display=\(config.displaySelection.description)")
        if let password = config.password {
            print("password=\(password)")
        } else {
            print("password=<none>")
        }
        print("Connect with vnc://\(config.bindAddress == "0.0.0.0" ? "127.0.0.1" : config.bindAddress):\(config.port)")

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
                    clipboard: clipboard
                ).run()
            } catch {
                fputs("client disconnected: \(error.localizedDescription)\n", stderr)
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
    private let encodingPreference: EncodingPreference
    private let capture: FramebufferSource
    private let input: InputController
    private let clipboard: ClipboardBridge
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
    private var updatesEnabled = false
    private var writerError: Error?
    private var updatesSent = 0
    private var bytesSent = 0

    init(
        socket: ClientSocket,
        password: String?,
        fps: Int,
        encodingPreference: EncodingPreference,
        capture: FramebufferSource,
        input: InputController,
        clipboard: ClipboardBridge
    ) throws {
        self.socket = socket
        self.password = password
        minimumFrameInterval = 0.85 / Double(fps)
        self.encodingPreference = encodingPreference
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
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
        print("client connected: \(versionText), framebuffer \(initialFrame.width)x\(initialFrame.height)")
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
        updatesEnabled = true
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

        while (!updatesEnabled || latestUpdateRequest == nil) && !stopped {
            state.wait()
        }
        guard !stopped else {
            return nil
        }

        return latestUpdateRequest
    }

    private func stopFramebufferWriter() {
        state.lock()
        stopped = true
        state.broadcast()
        state.unlock()
    }

    private func sendFramebufferUpdate(_ request: FramebufferUpdateRequest) throws {
        throttleFrameRate()

        let framebuffer = try capture.capture()
        let requested = request.rect
        let (format, encoding, previous, sentBefore) = stateSnapshotForEncoding()
        let shouldDiff = sentBefore
            && request.incremental
        let rects = RawEncoding.rectangles(
            current: framebuffer,
            previous: previous,
            requested: requested,
            incremental: shouldDiff
        )

        var response: [UInt8] = [0, 0]
        response += UInt16(rects.count).beBytes

        for rect in rects {
            response += UInt16(rect.x).beBytes
            response += UInt16(rect.y).beBytes
            response += UInt16(rect.width).beBytes
            response += UInt16(rect.height).beBytes
            switch encoding {
            case .zrle:
                response += UInt32(bitPattern: RFBEncoding.zrle.rawValue).beBytes
                response += try zrleEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            case .zlib:
                response += UInt32(bitPattern: RFBEncoding.zlib.rawValue).beBytes
                response += try zlibEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            case .raw:
                response += UInt32(bitPattern: RFBEncoding.raw.rawValue).beBytes
                response += try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            }
        }

        try socket.writeAll(response)
        state.lock()
        updatesSent += 1
        bytesSent += response.count
        if updatesSent == 1 || updatesSent % 60 == 0 {
            print("updates=\(updatesSent) encoding=\(encoding) last_rects=\(rects.count) total_bytes=\(bytesSent)")
        }
        previousFramebuffer = framebuffer
        currentLayout = framebuffer.layout
        hasSentFramebufferUpdate = true
        state.unlock()

        if let text = clipboard.localTextIfChanged() {
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
        if elapsed < minimumFrameInterval {
            usleep(useconds_t((minimumFrameInterval - elapsed) * 1_000_000))
        }
        lastFramebufferUpdate = Date()
    }

    private func handleKeyEvent() throws {
        let bytes = try socket.readExact(7)
        let down = bytes[0] != 0
        let keysym = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
        state.lock()
        let mapAltToCommand = isAppleScreenSharingClient
        state.unlock()
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
        input.pointer(buttonMask: mask, x: x, y: y, layout: layout)
    }

    private func handleClientCutText() throws {
        _ = try socket.readExact(3)
        let lengthBytes = try socket.readExact(4)
        let length = Int(UInt32.be(lengthBytes[0], lengthBytes[1], lengthBytes[2], lengthBytes[3]))
        let bytes = try socket.readExact(length)
        let text = String(decoding: bytes, as: UTF8.self)
        clipboard.setRemoteText(text)
    }

    private func sendServerCutText(_ text: String) throws {
        let payload = Array(text.utf8)
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += UInt32(payload.count).beBytes
        bytes += payload
        try socket.writeAll(bytes)
    }
}
