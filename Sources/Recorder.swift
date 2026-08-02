import AVFoundation

/// Mic capture, resampled to exactly what the STT socket wants: 16 kHz mono PCM16.
final class Recorder {

    /// Built fresh for every recording, never reused.
    ///
    /// An AVAudioEngine created before the microphone was granted keeps an input
    /// node that produces nothing, for the lifetime of the process. On a fresh
    /// install that is exactly the order events happen in — launch, then grant —
    /// so a long-lived engine records pure silence until the app is restarted.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: true)!

    private(set) var isRunning = false

    // Diagnostics — enough to say WHY nothing was heard instead of guessing.
    private(set) var framesCaptured: Int = 0
    private(set) var peakLevel: Float = 0
    private(set) var inputDescription = "unknown"

    static var defaultInputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
    }

    /// Raw PCM16 frames, ready to put on the wire.
    var onPCM: (Data) -> Void = { _ in }
    /// 0…1 input level, for the HUD meter.
    var onLevel: (Float) -> Void = { _ in }

    static func micAuthorization(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    func start() throws {
        guard !isRunning else { return }

        framesCaptured = 0
        peakLevel = 0

        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        inputDescription = "\(Self.defaultInputName) @ \(Int(inputFormat.sampleRate))Hz x\(inputFormat.channelCount)"

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            self.engine = nil
            throw NSError(domain: "Quill", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input device available — check Sound ▸ Input."
            ])
        }

        converter = AVAudioConverter(from: inputFormat, to: target)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        isRunning = false
        onLevel(0)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n {
                let v = channels[0][i]
                sum += v * v
            }
            let rms = sqrt(sum / Float(n))
            framesCaptured += n
            peakLevel = max(peakLevel, rms)
            onLevel(min(1, rms * 14))
        }

        guard let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        onPCM(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
    }
}
