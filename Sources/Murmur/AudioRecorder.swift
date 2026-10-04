import AVFoundation

/// Records the default input device as 16 kHz mono Float32, which is what Whisper wants.
/// A fresh AVAudioEngine is built per recording so device changes (AirPods etc.) just work,
/// and the mic indicator is only on while you're actually dictating.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// RMS level of the latest chunk, delivered on the main thread (drives the pill's meter).
    var onLevel: ((Float) -> Void)?
    private(set) var isRecording = false

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        if isRecording { _ = stop() }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw MurmurError("Allow microphone access, then try again")
        default:
            throw MurmurError("Mic access denied — System Settings › Privacy › Microphone")
        }

        lock.lock()
        samples = []
        samples.reserveCapacity(Int(Self.sampleRate) * 30)
        lock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw MurmurError("No microphone input available")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw MurmurError("Could not set up audio conversion") }
        converter.downmix = true

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, outFormat: outFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        isRecording = true
    }

    /// Stops recording and returns everything captured.
    func stop() -> [Float] {
        guard isRecording, let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRecording = false
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    // Runs on the audio thread.
    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outFormat: AVAudioFormat) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        guard count > 0 else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        let level = Self.rms(chunk)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

enum WAV {
    /// 16-bit PCM mono WAV in a temp file.
    static func writeTemp(samples: [Float], sampleRate: Int = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString).wav")
        try encode(samples: samples, sampleRate: sampleRate).write(to: url)
        return url
    }

    static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let dataSize = samples.count * 2
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(Data("RIFF".utf8)); u32(UInt32(36 + dataSize)); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(dataSize))

        data.reserveCapacity(data.count + dataSize)
        for s in samples {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_767)))
        }
        return data
    }
}
