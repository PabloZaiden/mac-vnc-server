import Foundation

struct PixelFormat: Equatable {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: Bool
    var trueColor: Bool
    var redMax: UInt16
    var greenMax: UInt16
    var blueMax: UInt16
    var redShift: UInt8
    var greenShift: UInt8
    var blueShift: UInt8

    static let serverDefault = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndian: Bool,
        trueColor: Bool,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count == 16 else {
            throw RFBError.protocolError("pixel format must be 16 bytes")
        }
        bitsPerPixel = bytes[0]
        depth = bytes[1]
        bigEndian = bytes[2] != 0
        trueColor = bytes[3] != 0
        redMax = UInt16.be(bytes[4], bytes[5])
        greenMax = UInt16.be(bytes[6], bytes[7])
        blueMax = UInt16.be(bytes[8], bytes[9])
        redShift = bytes[10]
        greenShift = bytes[11]
        blueShift = bytes[12]
    }

    var bytes: [UInt8] {
        [
            bitsPerPixel,
            depth,
            bigEndian ? 1 : 0,
            trueColor ? 1 : 0
        ] + redMax.beBytes + greenMax.beBytes + blueMax.beBytes + [
            redShift,
            greenShift,
            blueShift,
            0,
            0,
            0
        ]
    }
}

struct Framebuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra: [UInt8]
    let layout: VirtualDisplayLayout

    init(width: Int, height: Int, bytesPerRow: Int? = nil, bgra: [UInt8], layout: VirtualDisplayLayout) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow ?? width * 4
        self.bgra = bgra
        self.layout = layout
    }
}

struct Rect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

protocol FramebufferSource {
    func capture() throws -> Framebuffer
}

protocol InputController {
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout)
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool)
}

protocol ClipboardBridge {
    func localTextIfChanged() -> String?
    func setRemoteText(_ text: String)
}

enum RFBError: LocalizedError {
    case protocolError(String)
    case socketError(String)
    case unsupportedPixelFormat(PixelFormat)
    case captureFailed(String)
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .protocolError(let message):
            return "protocol error: \(message)"
        case .socketError(let message):
            return "socket error: \(message)"
        case .unsupportedPixelFormat(let format):
            return "unsupported pixel format: \(format)"
        case .captureFailed(let message):
            return "capture failed: \(message)"
        case .authenticationFailed:
            return "authentication failed"
        }
    }
}

extension UInt16 {
    static func be(_ high: UInt8, _ low: UInt8) -> UInt16 {
        (UInt16(high) << 8) | UInt16(low)
    }

    var beBytes: [UInt8] {
        [UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
    }
}

extension UInt32 {
    static func be(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    var beBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
    }
}
