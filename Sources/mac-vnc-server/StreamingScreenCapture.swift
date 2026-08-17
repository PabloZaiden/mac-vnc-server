import CoreGraphics
import CoreMedia
import CoreVideo
import AppKit
import Foundation
import ScreenCaptureKit

final class StreamingScreenCapture: @unchecked Sendable, FramebufferSource {
    private let scale: CGFloat
    private let fps: Int
    private let displaySelection: DisplaySelection
    private let streamEventSink: StreamEventSink
    private let stateLock = NSLock()
    private let recoveryLock = NSLock()
    private var store: StreamingFrameStore
    private var streams: [SCStream]
    private var outputs: [ScreenCaptureStreamOutput]
    private var delegates: [ScreenCaptureStreamDelegate]
    private var wakeObserver: NSObjectProtocol?
    private var recoveryScheduled = false

    init(scale: Double, fps: Int, displaySelection: DisplaySelection) async throws {
        self.scale = CGFloat(scale)
        self.fps = fps
        self.displaySelection = displaySelection

        let eventSink = StreamEventSink()
        let started = try await Self.start(
            scale: self.scale,
            fps: fps,
            displaySelection: displaySelection,
            eventSink: eventSink
        )

        guard started.store.waitForFirstFrames(timeout: 5) else {
            await Self.stopStreams(started.streams)
            throw RFBError.captureFailed("ScreenCaptureKit did not produce frames; check Screen Recording permission")
        }

        streamEventSink = eventSink
        store = started.store
        streams = started.streams
        outputs = started.outputs
        delegates = started.delegates
        eventSink.attach(owner: self)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRecovery(reason: "screens did wake")
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func capture() throws -> Framebuffer {
        try currentStore().snapshot()
    }

    private func currentStore() -> StreamingFrameStore {
        stateLock.lock()
        defer { stateLock.unlock() }
        return store
    }

    static func displayCount() async throws -> Int {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.count
    }

    private static func start(
        scale: CGFloat,
        fps: Int,
        displaySelection: DisplaySelection,
        eventSink: StreamEventSink
    ) async throws -> StartedCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let selectedDisplays = try selectDisplays(from: orderedDisplays(content.displays), displaySelection: displaySelection)
        let displays = selectedDisplays.map { display in
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
        var delegates: [ScreenCaptureStreamDelegate] = []

        do {
            for display in selectedDisplays {
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

                let delegate = ScreenCaptureStreamDelegate(eventSink: eventSink)
                let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
                let output = ScreenCaptureStreamOutput(displayID: display.displayID, store: store)
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "mac-vnc-server.sck.\(display.displayID)")
                )
                streams.append(stream)
                outputs.append(output)
                delegates.append(delegate)
                try await stream.startCapture()
            }
        } catch {
            await stopStreams(streams)
            throw error
        }

        return StartedCapture(store: store, streams: streams, outputs: outputs, delegates: delegates)
    }

    private func scheduleRecovery(reason: String) {
        recoveryLock.lock()
        guard !recoveryScheduled else {
            recoveryLock.unlock()
            return
        }
        recoveryScheduled = true
        recoveryLock.unlock()

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: .seconds(1))
                try await restartCapture(reason: reason)
            } catch is CancellationError {
                // The capture owner is shutting down.
            } catch {
                fputs("ScreenCaptureKit recovery failed: \(error.localizedDescription)\n", stderr)
            }

            finishRecoveryScheduling()
        }
    }

    private func restartCapture(reason: String) async throws {
        print("ScreenCaptureKit: rebuilding capture after \(reason)")

        let oldStreams = currentStreams()
        await Self.stopStreams(oldStreams)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                let started = try await Self.start(
                    scale: scale,
                    fps: fps,
                    displaySelection: displaySelection,
                    eventSink: streamEventSink
                )
                guard started.store.waitForFirstFrames(timeout: 5) else {
                    await Self.stopStreams(started.streams)
                    throw RFBError.captureFailed("ScreenCaptureKit did not produce frames during recovery")
                }

                install(started)

                print("ScreenCaptureKit: capture recovered")
                return
            } catch {
                lastError = error
                fputs(
                    "ScreenCaptureKit recovery attempt \(attempt)/3 failed: \(error.localizedDescription)\n",
                    stderr
                )
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }

        throw lastError ?? RFBError.captureFailed("ScreenCaptureKit recovery failed")
    }

    private func currentStreams() -> [SCStream] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streams
    }

    fileprivate func streamDidStop(_ stream: SCStream, reason: String) {
        stateLock.lock()
        let isCurrentStream = streams.contains { $0 === stream }
        stateLock.unlock()

        guard isCurrentStream else {
            return
        }
        scheduleRecovery(reason: "stream stopped: \(reason)")
    }

    private func install(_ started: StartedCapture) {
        stateLock.lock()
        store = started.store
        streams = started.streams
        outputs = started.outputs
        delegates = started.delegates
        stateLock.unlock()
    }

    private func finishRecoveryScheduling() {
        recoveryLock.lock()
        recoveryScheduled = false
        recoveryLock.unlock()
    }

    private static func stopStreams(_ streams: [SCStream]) async {
        for stream in streams {
            do {
                try await stream.stopCapture()
            } catch {
                fputs("ScreenCaptureKit stream stop failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func selectDisplays(from displays: [SCDisplay], displaySelection: DisplaySelection) throws -> [SCDisplay] {
        guard !displays.isEmpty else {
            throw RFBError.captureFailed("ScreenCaptureKit found no displays")
        }

        switch displaySelection {
        case .automatic, .all:
            return displays
        case .display(let index):
            guard displays.indices.contains(index - 1) else {
                throw RFBError.captureFailed("display \(index) is not available; found \(displays.count) display(s)")
            }
            return [displays[index - 1]]
        }
    }

    private static func orderedDisplays(_ displays: [SCDisplay]) -> [SCDisplay] {
        guard let activeDisplayIDs = try? MacScreenCapture.activeDisplayIDs() else {
            return displays
        }

        let order = Dictionary(uniqueKeysWithValues: activeDisplayIDs.enumerated().map { ($0.element, $0.offset) })
        return displays.sorted {
            (order[$0.displayID] ?? Int.max, $0.displayID) < (order[$1.displayID] ?? Int.max, $1.displayID)
        }
    }
}

private struct StartedCapture {
    let store: StreamingFrameStore
    let streams: [SCStream]
    let outputs: [ScreenCaptureStreamOutput]
    let delegates: [ScreenCaptureStreamDelegate]
}

private final class StreamEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: StreamingScreenCapture?
    private var pendingEvents: [(stream: SCStream, reason: String)] = []

    func attach(owner: StreamingScreenCapture) {
        lock.lock()
        self.owner = owner
        let pendingEvents = pendingEvents
        self.pendingEvents.removeAll(keepingCapacity: true)
        lock.unlock()

        for event in pendingEvents {
            owner.streamDidStop(event.stream, reason: event.reason)
        }
    }

    func streamDidStop(_ stream: SCStream, error: Error) {
        let reason = error.localizedDescription

        lock.lock()
        guard let owner else {
            pendingEvents.append((stream: stream, reason: reason))
            lock.unlock()
            return
        }
        lock.unlock()

        owner.streamDidStop(stream, reason: reason)
    }
}

private final class ScreenCaptureStreamDelegate: NSObject, SCStreamDelegate {
    private let eventSink: StreamEventSink

    init(eventSink: StreamEventSink) {
        self.eventSink = eventSink
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        eventSink.streamDidStop(stream, error: error)
    }
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
