// The chosen mic, opened directly with AVCaptureSession — independent of the Mac's default input. When AirPods or an iPhone
// became the default (and OBS / screen recording opened it), the engine kept being reconfigured into the wrong format and
// Sasarisa went deaf for minutes (10/25 17:07). Chunks come out as AVAudioPCMBuffers for Ear.process.
import AVFoundation
import CoreMedia

final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let uid: String
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sasarisa.mic")
    var onBuffer: (AVAudioPCMBuffer) -> Void = { _ in }

    init(uid: String) { self.uid = uid }

    func start() throws {
        guard let dev = AVCaptureDevice(uniqueID: uid) else { throw NSError(domain: "Ear", code: 3, userInfo: [NSLocalizedDescriptionKey: "chosen mic not available"]) }
        let input = try AVCaptureDeviceInput(device: dev)
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                             AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1]
        out.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(out) else { session.commitConfiguration(); throw NSError(domain: "Ear", code: 4, userInfo: [NSLocalizedDescriptionKey: "can't open the chosen mic"]) }
        session.addInput(input); session.addOutput(out)
        session.commitConfiguration()
        session.startRunning()
    }
    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        onBuffer(pcm)
    }
}
