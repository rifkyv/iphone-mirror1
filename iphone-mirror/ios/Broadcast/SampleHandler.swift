import CoreMedia
import ReplayKit

/// Entry point of the broadcast extension. iOS calls this while the screen broadcast runs.
class SampleHandler: RPBroadcastSampleHandler {
    private let core = MirrorCore()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        core.start()
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        core.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            core.handleVideo(sampleBuffer)
        case .audioApp:
            core.handleAudio(sampleBuffer)
        case .audioMic:
            break
        @unknown default:
            break
        }
    }
}
