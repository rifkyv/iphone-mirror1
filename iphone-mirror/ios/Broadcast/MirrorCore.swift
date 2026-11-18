import CoreMedia
import CoreVideo
import Foundation
import ReplayKit

/// Glue between ReplayKit, the encoder and the USB stream server.
final class MirrorCore {
    static let port: UInt16 = 7890

    private let server = StreamServer(port: MirrorCore.port)

    // Encoder state, guarded by `lock`.
    private let lock = NSLock()
    private var settings: EncoderSettings?
    private var audioEnabled = false
    private var encoder: VideoEncoder?
    private var lastBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var lastEncodedPTS = CMTime.invalid
    private var orientation: UInt8 = 1
    private var screenWidth = 0
    private var screenHeight = 0

    // Output state, guarded by `statsLock` (touched from encoder callbacks).
    private let statsLock = NSLock()
    private var framesThisSecond = 0
    private var bytesThisSecond = 0
    private var droppedTotal = 0
    private var needKeyframe = false

    private var statsTimer: DispatchSourceTimer?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: - lifecycle

    func start() {
        server.onConnect = { [weak self] in self?.clientConnected() }
        server.onDisconnect = { [weak self] in self?.clientDisconnected() }
        server.onCommand = { [weak self] command in self?.handle(command: command) }
        server.start()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mirror.stats"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendStats() }
        timer.resume()
        statsTimer = timer
    }

    func stop() {
        statsTimer?.cancel()
        statsTimer = nil
        server.stop()
        lock.lock()
        encoder?.invalidate()
        encoder = nil
        lastBuffer = nil
        lock.unlock()
    }

    // MARK: - client events

    private func clientConnected() {
        lock.lock()
        settings = nil
        audioEnabled = false
        encoder?.invalidate()
        encoder = nil
        let width = screenWidth
        let height = screenHeight
        lock.unlock()
        sendJSON(type: 1, ["proto": 1, "app": appVersion, "screen": [width, height]], droppable: false)
    }

    private func clientDisconnected() {
        lock.lock()
        settings = nil
        audioEnabled = false
        encoder?.invalidate()
        encoder = nil
        lock.unlock()
    }

    private func handle(command: [String: Any]) {
        let name = command["cmd"] as? String ?? "config"
        if name == "keyframe" {
            statsLock.lock()
            needKeyframe = true
            statsLock.unlock()
            repeatLastFrame()
            return
        }
        guard name == "config" else { return }

        let codec = command["codec"] as? String ?? "h264"
        let bitrate = (command["bitrate"] as? NSNumber)?.intValue ?? 20_000_000
        let fps = (command["fps"] as? NSNumber)?.intValue ?? 60
        let maxLongSide = (command["max_long_side"] as? NSNumber)?.intValue ?? 1920
        let keyframeInterval = (command["keyframe_interval"] as? NSNumber)?.doubleValue ?? 2.0
        let audio = (command["audio"] as? NSNumber)?.boolValue ?? true

        let newSettings = EncoderSettings(
            hevc: codec == "hevc",
            bitrate: min(max(bitrate, 1_000_000), 100_000_000),
            fps: min(max(fps, 10), 60),
            maxLongSide: max(0, maxLongSide),
            keyframeInterval: min(max(keyframeInterval, 0.5), 10.0)
        )
        lock.lock()
        settings = newSettings
        audioEnabled = audio
        encoder?.invalidate()
        encoder = nil  // rebuilt with the new settings on the next frame
        lastEncodedPTS = .invalid
        lock.unlock()
        repeatLastFrame()
    }

    // MARK: - video

    func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var newOrientation: UInt8 = 1
        if let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            newOrientation = value.uint8Value
        }

        lock.lock()
        defer { lock.unlock() }
        lastBuffer = pixelBuffer
        lastPTS = pts
        orientation = newOrientation
        screenWidth = CVPixelBufferGetWidth(pixelBuffer)
        screenHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard let current = settings, server.hasClient else { return }
        if lastEncodedPTS.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastEncodedPTS))
            if delta >= 0 && delta < (1.0 / Double(current.fps)) * 0.85 {
                return  // frame rate cap
            }
        }
        encodeLocked(pixelBuffer, pts: pts)
    }

    /// Re-encode the last screen picture, so the PC gets an image right away even when the
    /// screen is static (ReplayKit only delivers frames when something changes).
    private func repeatLastFrame() {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer = lastBuffer, settings != nil, server.hasClient else { return }
        let pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
        lastPTS = pts
        statsLock.lock()
        needKeyframe = true
        statsLock.unlock()
        encodeLocked(buffer, pts: pts)
    }

    /// Caller holds `lock`.
    private func encodeLocked(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard var current = settings else { return }
        if encoder == nil {
            var created = VideoEncoder(
                sourceWidth: CVPixelBufferGetWidth(buffer),
                sourceHeight: CVPixelBufferGetHeight(buffer),
                settings: current
            )
            if created == nil && current.hevc {
                // HEVC not available: fall back to H.264. Packets carry the codec, the PC follows.
                current.hevc = false
                settings = current
                created = VideoEncoder(
                    sourceWidth: CVPixelBufferGetWidth(buffer),
                    sourceHeight: CVPixelBufferGetHeight(buffer),
                    settings: current
                )
            }
            guard let made = created else { return }
            let isHEVC = current.hevc
            made.onOutput = { [weak self] data, isKeyframe, ptsMicros, tag in
                self?.emitVideo(data, isKeyframe: isKeyframe, hevc: isHEVC, ptsMicros: ptsMicros, orientation: tag)
            }
            encoder = made
            statsLock.lock()
            needKeyframe = true
            statsLock.unlock()
        }
        guard let encoder = encoder else { return }

        statsLock.lock()
        let wantKeyframe = needKeyframe
        statsLock.unlock()
        if wantKeyframe {
            encoder.requestKeyframe()
        }
        encoder.encode(buffer, pts: pts, tag: orientation)
        lastEncodedPTS = pts
    }

    private func emitVideo(_ data: Data, isKeyframe: Bool, hevc: Bool, ptsMicros: UInt64, orientation: UInt8) {
        statsLock.lock()
        let waiting = needKeyframe
        statsLock.unlock()
        if waiting && !isKeyframe {
            // A frame was dropped earlier; P-frames are useless until the next keyframe.
            statsLock.lock()
            droppedTotal += 1
            statsLock.unlock()
            return
        }

        var payload = Data(capacity: data.count + 10)
        let flags: UInt8 = (isKeyframe ? 1 : 0) | (hevc ? 2 : 0)
        payload.append(flags)
        payload.append(orientation)
        var ptsBE = ptsMicros.bigEndian
        withUnsafeBytes(of: &ptsBE) { payload.append(contentsOf: $0) }
        payload.append(data)

        // Keep the queue short so latency stays low. Keyframes get more room.
        let limit = isKeyframe ? 12 * 1024 * 1024 : 2 * 1024 * 1024
        let sent = server.send(MirrorCore.message(type: 2, payload: payload), droppable: true, maxQueued: limit)

        statsLock.lock()
        if sent {
            framesThisSecond += 1
            bytesThisSecond += payload.count
            if isKeyframe { needKeyframe = false }
        } else {
            droppedTotal += 1
            needKeyframe = true
        }
        statsLock.unlock()
    }

    // MARK: - audio

    func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let enabled = audioEnabled && settings != nil
        lock.unlock()
        guard enabled, server.hasClient, let payload = AudioPacker.pack(sampleBuffer) else { return }
        server.send(MirrorCore.message(type: 3, payload: payload), droppable: true, maxQueued: 2 * 1024 * 1024)
    }

    // MARK: - stats and helpers

    private func sendStats() {
        guard server.hasClient else { return }
        statsLock.lock()
        let fps = framesThisSecond
        let bytes = bytesThisSecond
        let dropped = droppedTotal
        framesThisSecond = 0
        bytesThisSecond = 0
        statsLock.unlock()

        lock.lock()
        let current = settings
        let width = Int(encoder?.width ?? 0)
        let height = Int(encoder?.height ?? 0)
        lock.unlock()

        var stats: [String: Any] = ["fps": fps, "kbps": bytes * 8 / 1000, "dropped": dropped, "w": width, "h": height]
        if let current = current {
            stats["codec"] = current.hevc ? "hevc" : "h264"
            stats["bitrate"] = current.bitrate
        }
        sendJSON(type: 4, stats, droppable: true)
    }

    private func sendJSON(type: UInt8, _ object: [String: Any], droppable: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        server.send(MirrorCore.message(type: type, payload: data), droppable: droppable, maxQueued: 8 * 1024 * 1024)
    }

    static func message(type: UInt8, payload: Data) -> Data {
        var message = Data(capacity: payload.count + 5)
        message.append(type)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(payload)
        return message
    }
}
