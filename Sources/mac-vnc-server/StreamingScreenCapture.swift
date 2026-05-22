import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class StreamingScreenCapture: FramebufferSource {
    private let store: StreamingFrameStore
    private var streams: [SCStream]
    private var outputs: [ScreenCaptureStreamOutput]

    init(scale: Double, fps: Int) async throws {
        let started = try await Self.start(scale: CGFloat(scale), fps: fps)
        store = started.store
        streams = started.streams
        outputs = started.outputs

        guard store.waitForFirstFrames(timeout: 5) else {
            throw RFBError.captureFailed("ScreenCaptureKit did not produce frames; check Screen Recording permission")
        }
    }

    func capture() throws -> Framebuffer {
        try store.snapshot()
    }

    private static func start(scale: CGFloat, fps: Int) async throws -> StartedCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.map { display in
            VirtualDisplay(
                id: display.displayID,
                bounds: CGDisplayBounds(display.displayID),
                pixelWidth: display.width,
                pixelHeight: display.height
            )
        }
        guard !displays.isEmpty else {
            throw RFBError.captureFailed("ScreenCaptureKit found no displays")
        }

        let layout = VirtualDisplayLayout(displays: displays, scaleOverride: scale)
        let store = StreamingFrameStore(layout: layout, expectedDisplayIDs: Set(displays.map(\.id)))
        var streams: [SCStream] = []
        var outputs: [ScreenCaptureStreamOutput] = []

        for display in content.displays {
            let bounds = CGDisplayBounds(display.displayID)
            let width = max(1, Int(bounds.width * scale))
            let height = max(1, Int(bounds.height * scale))
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 5
            config.showsCursor = true

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let output = ScreenCaptureStreamOutput(displayID: display.displayID, store: store)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "mac-vnc-server.sck.\(display.displayID)"))
            try await stream.startCapture()
            streams.append(stream)
            outputs.append(output)
        }

        return StartedCapture(store: store, streams: streams, outputs: outputs)
    }
}

private struct StartedCapture {
    let store: StreamingFrameStore
    let streams: [SCStream]
    let outputs: [ScreenCaptureStreamOutput]
}

private struct DisplayFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra: [UInt8]
}

private final class StreamingFrameStore: @unchecked Sendable {
    private let condition = NSCondition()
    private let layout: VirtualDisplayLayout
    private let expectedDisplayIDs: Set<CGDirectDisplayID>
    private var frames: [CGDirectDisplayID: DisplayFrame] = [:]

    init(layout: VirtualDisplayLayout, expectedDisplayIDs: Set<CGDirectDisplayID>) {
        self.layout = layout
        self.expectedDisplayIDs = expectedDisplayIDs
    }

    func update(displayID: CGDirectDisplayID, pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteCount = bytesPerRow * height
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = bytes.withUnsafeMutableBytes { destination in
            memcpy(destination.baseAddress!, baseAddress, byteCount)
        }

        condition.lock()
        frames[displayID] = DisplayFrame(width: width, height: height, bytesPerRow: bytesPerRow, bgra: bytes)
        condition.broadcast()
        condition.unlock()
    }

    func waitForFirstFrames(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while !expectedDisplayIDs.isSubset(of: Set(frames.keys)) {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    func snapshot() throws -> Framebuffer {
        condition.lock()
        let currentFrames = frames
        condition.unlock()

        guard !currentFrames.isEmpty else {
            throw RFBError.captureFailed("no ScreenCaptureKit frame available yet")
        }

        if layout.displays.count == 1,
           let display = layout.displays.first,
           let frame = currentFrames[display.id],
           frame.width == layout.width,
           frame.height == layout.height,
           frame.bytesPerRow == layout.width * 4 {
            return Framebuffer(width: layout.width, height: layout.height, bytesPerRow: frame.bytesPerRow, bgra: frame.bgra, layout: layout)
        }

        let bytesPerRow = layout.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * layout.height)

        for display in layout.displays {
            guard let frame = currentFrames[display.id] else {
                continue
            }

            let rect = layout.framebufferRect(for: display)
            let destinationX = max(0, Int(rect.minX.rounded(.down)))
            let destinationY = max(0, Int(rect.minY.rounded(.down)))
            let copyWidth = min(frame.width, layout.width - destinationX)
            let copyHeight = min(frame.height, layout.height - destinationY)
            guard copyWidth > 0, copyHeight > 0 else {
                continue
            }

            for row in 0..<copyHeight {
                let sourceOffset = row * frame.bytesPerRow
                let destinationOffset = (destinationY + row) * bytesPerRow + destinationX * 4
                _ = pixels.withUnsafeMutableBytes { destination in
                    frame.bgra.withUnsafeBytes { source in
                        memcpy(
                            destination.baseAddress!.advanced(by: destinationOffset),
                            source.baseAddress!.advanced(by: sourceOffset),
                            copyWidth * 4
                        )
                    }
                }
            }
        }

        return Framebuffer(width: layout.width, height: layout.height, bytesPerRow: bytesPerRow, bgra: pixels, layout: layout)
    }
}

private final class ScreenCaptureStreamOutput: NSObject, SCStreamOutput {
    private let displayID: CGDirectDisplayID
    private let store: StreamingFrameStore

    init(displayID: CGDirectDisplayID, store: StreamingFrameStore) {
        self.displayID = displayID
        self.store = store
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        store.update(displayID: displayID, pixelBuffer: pixelBuffer)
    }
}
