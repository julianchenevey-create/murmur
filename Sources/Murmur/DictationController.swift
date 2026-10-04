import AppKit

/// The dictation state machine.
///
///   idle ──press──▶ recordingHold ──release (long)──▶ processing ──▶ paste ──▶ idle
///                        │
///                        ├─release (short tap, no earlier tap)──▶ discard ──▶ idle
///                        └─release (short tap right after a tap)──▶ recordingHandsFree
///   recordingHandsFree ──press / time limit──▶ processing
///   Esc: recording ──▶ discard;  processing ──▶ cancel (kills whisper / the HTTP request)
///
/// Everything here runs on the main thread.
final class DictationController {
    enum State { case disabled, waitingForPermission, idle, recordingHold, recordingHandsFree, processing }

    private(set) var state: State = .disabled {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    private(set) var config: Config
    private var env: Env

    private let recorder = AudioRecorder()
    private let pill = PillWindow()
    private let inserter = Inserter()
    private var monitor: HotkeyMonitor?
    private var retryTimer: Timer?
    private var askedForInputMonitoring = false

    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var pendingDoubleTap = false
    private var swallowRelease = false
    private var recordStartedAt = Date()
    private var tickTimer: Timer?
    private var handsFreeTimer: Timer?

    private var job: Task<Void, Never>?
    /// Bumped whenever in-flight work should be ignored (Esc, disable, new session).
    private var generation = 0
    private var errorHideWork: DispatchWorkItem?

    init(config: Config, env: Env) {
        self.config = config
        self.env = env
        recorder.onLevel = { [weak self] level in self?.pill.model.level = level }
    }

    var isEnabled: Bool { state != .disabled }

    // MARK: - Enable / reload

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if state == .disabled { startMonitor() }
        } else {
            stopMonitor()
            abortEverything()
            state = .disabled
        }
    }

    func reload(config: Config, env: Env) {
        let wasEnabled = isEnabled
        stopMonitor()
        abortEverything()
        self.config = config
        self.env = env
        state = .disabled
        if wasEnabled { startMonitor() }
    }

    private func startMonitor() {
        stopMonitor()
        let spec: HotkeySpec
        if let parsed = HotkeySpec.parse(config.hotkey) {
            spec = parsed
        } else {
            Log.write("Unrecognized hotkey \"\(config.hotkey)\", falling back to fn")
            showError("Unknown hotkey \"\(config.hotkey)\", using fn")
            spec = .fn
        }
        let monitor = HotkeyMonitor(spec: spec)
        monitor.onPress = { [weak self] in self?.hotkeyPressed() }
        monitor.onRelease = { [weak self] in self?.hotkeyReleased() }
        monitor.onEscape = { [weak self] in self?.escapePressed() }
        monitor.onOtherKey = { [weak self] in self?.otherKeyPressed() }

        if monitor.start() {
            self.monitor = monitor
            state = .idle
            Log.write("listening for hotkey \(config.hotkey)")
        } else {
            // No Accessibility (or, on some setups, Input Monitoring) permission yet. Keep retrying.
            state = .waitingForPermission
            if Permissions.accessibility && !askedForInputMonitoring {
                askedForInputMonitoring = true
                Permissions.requestInputMonitoring()
            }
            let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in self?.startMonitor() }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    private func stopMonitor() {
        retryTimer?.invalidate()
        retryTimer = nil
        monitor?.stop()
        monitor = nil
    }

    // MARK: - Hotkey events

    private func hotkeyPressed() {
        switch state {
        case .idle:
            pendingDoubleTap = Date().timeIntervalSince(lastTapAt) * 1000 < Double(config.doubleTapWindowMs)
            pressedAt = Date()
            startRecording()
        case .recordingHandsFree:
            swallowRelease = true
            finishRecording()
        default:
            break // ignore presses while a transcription is running
        }
    }

    private func hotkeyReleased() {
        if swallowRelease {
            swallowRelease = false
            return
        }
        guard state == .recordingHold else { return }

        let heldMs = Date().timeIntervalSince(pressedAt) * 1000
        if heldMs >= Double(config.tapThresholdMs) {
            lastTapAt = .distantPast
            finishRecording()
        } else if pendingDoubleTap {
            lastTapAt = .distantPast
            enterHandsFree()
        } else {
            lastTapAt = Date()
            discardRecording()
        }
    }

    private func escapePressed() {
        switch state {
        case .recordingHold, .recordingHandsFree:
            Log.write("recording cancelled (Esc)")
            discardRecording()
        case .processing:
            Log.write("transcription cancelled (Esc)")
            generation += 1
            job?.cancel()
            job = nil
            pill.hide()
            state = .idle
        default:
            break
        }
    }

    /// Holding a modifier hotkey and pressing another key (fn+F1, ctrl+C...) is a shortcut,
    /// not a dictation.
    private func otherKeyPressed() {
        guard state == .recordingHold, monitor?.spec.isModifierOnly == true else { return }
        discardRecording()
    }

    // MARK: - Recording

    private func startRecording() {
        do {
            try recorder.start()
        } catch {
            Log.write("could not start recording: \(error)")
            showError(error.localizedDescription)
            return
        }
        errorHideWork?.cancel()
        recordStartedAt = Date()
        state = .recordingHold
        pill.model.phase = .hold
        pill.model.elapsed = 0
        pill.model.level = 0
        pill.model.limit = config.handsFreeMaxSeconds
        if config.showPill { pill.show() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pill.model.elapsed = Int(Date().timeIntervalSince(self.recordStartedAt))
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func enterHandsFree() {
        state = .recordingHandsFree
        pill.model.phase = .handsFree
        let remaining = max(1, Double(config.handsFreeMaxSeconds) - Date().timeIntervalSince(recordStartedAt))
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in self?.handsFreeTimedOut() }
        RunLoop.main.add(timer, forMode: .common)
        handsFreeTimer = timer
    }

    private func handsFreeTimedOut() {
        guard state == .recordingHandsFree else { return }
        Log.write("hands-free session hit the \(config.handsFreeMaxSeconds)s limit")
        if config.handsFreeTimeoutAction.lowercased() == "discard" {
            discardRecording()
        } else {
            finishRecording()
        }
    }

    private func discardRecording() {
        _ = recorder.stop()
        stopTimers()
        pill.hide()
        state = .idle
    }

    private func finishRecording() {
        let samples = recorder.stop()
        stopTimers()

        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        // Whisper hallucinates on silence ("Thank you."), so don't send it near-empty audio.
        guard seconds >= 0.3, AudioRecorder.rms(samples) > 0.0008 else {
            Log.write(String(format: "skipped %.2fs recording (too short or silent)", seconds))
            pill.hide()
            state = .idle
            return
        }

        state = .processing
        pill.model.phase = .processing
        pill.model.status = "Transcribing…"
        generation += 1
        let gen = generation
        let config = self.config
        let env = self.env
        job = Task { @MainActor in
            await self.process(samples: samples, config: config, env: env, gen: gen)
        }
    }

    @MainActor
    private func process(samples: [Float], config: Config, env: Env, gen: Int) async {
        let started = Date()
        do {
            let wav = try WAV.writeTemp(samples: samples)
            defer { try? FileManager.default.removeItem(at: wav) }

            let transcriber = try TranscriberFactory.make(config, env)
            let raw = TranscriptFilter.clean(try await transcriber.transcribe(wav: wav))
            guard gen == generation, !Task.isCancelled else { return }
            guard !raw.isEmpty else {
                finish(gen)
                return
            }

            var text = raw
            if let cleaner = Cleaner.make(config, env) {
                pill.model.status = "Polishing…"
                do {
                    text = try await cleaner.clean(raw)
                } catch {
                    if Task.isCancelled { return }
                    Log.write("cleanup failed, pasting raw transcript: \(error.localizedDescription)")
                }
            }
            guard gen == generation, !Task.isCancelled else { return }

            if config.insert.trailingSpace { text += " " }
            inserter.insert(text, using: config.insert)
            Log.write(String(format: "inserted %d chars (%.1fs audio, %.1fs processing)",
                             text.count, Double(samples.count) / AudioRecorder.sampleRate,
                             Date().timeIntervalSince(started)))
            finish(gen)
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            Log.write("dictation failed: \(error.localizedDescription)")
            state = .idle
            showError(error.localizedDescription)
        }
    }

    private func finish(_ gen: Int) {
        guard gen == generation else { return }
        job = nil
        pill.hide()
        state = .idle
    }

    private func stopTimers() {
        tickTimer?.invalidate()
        tickTimer = nil
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
    }

    private func abortEverything() {
        if recorder.isRecording { _ = recorder.stop() }
        stopTimers()
        generation += 1
        job?.cancel()
        job = nil
        swallowRelease = false
        pill.hide()
    }

    // MARK: - Errors

    /// Shows a message in the pill for a few seconds (shown even when showPill is off).
    func showError(_ message: String) {
        pill.model.phase = .error
        pill.model.status = message
        pill.show()
        errorHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pill.model.phase == .error else { return }
            self.pill.hide()
        }
        errorHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
