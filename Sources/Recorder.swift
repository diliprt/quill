import AVFoundation

/// Mic capture, resampled to exactly what the STT socket wants: 16 kHz mono PCM16.
final class Recorder {

    /// Built between recordings, but never carried across a permission change.
    ///
    /// An AVAudioEngine created before the microphone was granted keeps an input
    /// node that produces nothing, for the lifetime of the process. On a fresh
    /// install that is exactly the order events happen in — launch, then grant —
    /// so a long-lived engine records pure silence until the app is restarted.
    /// `prewarm()` therefore refuses to run until the grant is in place.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: true)!

    private(set) var isRunning = false
    /// An engine is built and prepared, waiting for `start()`.
    private var isPrewarmed = false
    /// Whether the recording in progress started from a prewarmed engine.
    private(set) var startedFromPrewarm = false

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

    /// Build the engine, tap and converter without opening the microphone.
    ///
    /// `prepare()` allocates the render resources; audio only flows — and the
    /// system recording indicator only lights — once `start()` is called. Doing
    /// this ahead of the keypress is what makes the first word survive: building
    /// from scratch inside `start()` cost 90–250ms, and anything said in that
    /// window was never recorded at all ("alright testing" arrived as
    /// "testing").
    ///
    /// Only ever called once the microphone is already authorised: an engine
    /// created before the grant keeps an input node that produces silence for
    /// the lifetime of the process.
    func prewarm() {
        guard !isRunning, engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do {
            try build()
            isPrewarmed = true
        } catch {
            teardown()
            isPrewarmed = false
        }
    }

    /// Drop a prewarmed (not yet started) engine — used when the audio route
    /// changes underneath us, so the next recording rebuilds on the new device.
    func invalidatePrewarm() {
        // Keyed on the engine, not `isPrewarmed`: a start() that failed and
        // rebuilt leaves an engine behind with the flag cleared, and gating on
        // the flag made that engine impossible to ever replace — it stayed bound
        // to the old input device until the app restarted.
        guard !isRunning, engine != nil else { return }
        teardown()
    }

    func start() throws {
        guard !isRunning else { return }

        framesCaptured = 0
        peakLevel = 0

        if engine == nil {
            try build()
            isPrewarmed = false
        }
        guard let engine else {
            throw NSError(domain: "Quill", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input device available — check Sound ▸ Input."
            ])
        }

        do {
            try engine.start()
        } catch {
            // A prewarmed engine can go stale (device unplugged, sleep). Rebuild
            // once rather than failing the dictation the user just started.
            teardown()
            try build()
            isPrewarmed = false
            guard let fresh = self.engine else { throw error }
            try fresh.start()
        }
        startedFromPrewarm = isPrewarmed
        isPrewarmed = false
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
        onLevel(0)
    }

    private func build() throws {
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
        // 2048 restored: halving it to 1024 shipped alongside a reported
        // transcription-quality drop; the ~20ms it saved is not worth any risk
        // on the audio path.
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
    }

    private func teardown() {
        isPrewarmed = false
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        self.engine = nil
        converter = nil
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
