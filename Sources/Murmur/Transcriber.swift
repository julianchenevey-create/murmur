import Foundation

protocol Transcriber {
    func transcribe(wav: URL) async throws -> String
}

enum TranscriberFactory {
    static func make(_ config: Config, _ env: Env) throws -> Transcriber {
        let t = config.transcription
        var engine = t.engine.lowercased()
        if engine == "auto" {
            engine = env["GROQ_API_KEY"] != nil ? "groq" : env["OPENAI_API_KEY"] != nil ? "openai" : "local"
        }

        switch engine {
        case "groq":
            guard let key = env["GROQ_API_KEY"] else { throw MurmurError("engine is groq but GROQ_API_KEY is not in .env") }
            return APIWhisper(endpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
                              key: key, model: t.groqModel, language: t.language, prompt: t.vocabulary)
        case "openai":
            guard let key = env["OPENAI_API_KEY"] else { throw MurmurError("engine is openai but OPENAI_API_KEY is not in .env") }
            return APIWhisper(endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                              key: key, model: t.openaiModel, language: t.language, prompt: t.vocabulary)
        case "local":
            if !t.serverURL.isEmpty {
                guard let base = URL(string: t.serverURL) else { throw MurmurError("Invalid transcription.serverURL") }
                return APIWhisper(endpoint: base.appendingPathComponent("inference"),
                                  key: nil, model: "", language: t.language, prompt: t.vocabulary)
            }
            guard let binary = WhisperCLI.locate(t.whisperCliPath) else {
                throw MurmurError("whisper-cli not found — run: brew install whisper-cpp")
            }
            let model = Paths.expand(t.modelPath)
            guard FileManager.default.fileExists(atPath: model) else {
                throw MurmurError("Model missing: \(model) — run scripts/download-model.sh")
            }
            return WhisperCLI(binary: binary, model: model, language: t.language,
                              threads: t.threads, prompt: t.vocabulary)
        default:
            throw MurmurError("Unknown transcription.engine \"\(t.engine)\"")
        }
    }
}

/// Runs whisper.cpp's CLI once per dictation. Fully offline.
struct WhisperCLI: Transcriber {
    let binary: URL
    let model: String
    let language: String
    let threads: Int
    let prompt: String

    static func locate(_ configured: String) -> URL? {
        var candidates = [
            "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp",
        ]
        if !configured.isEmpty { candidates.insert(Paths.expand(configured), at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func transcribe(wav: URL) async throws -> String {
        let base = wav.deletingPathExtension()
        var args = ["-m", model, "-f", wav.path,
                    "-l", language.isEmpty ? "auto" : language,
                    "-nt", "-np", "-otxt", "-of", base.path]
        if threads > 0 { args += ["-t", String(threads)] }
        if !prompt.isEmpty { args += ["--prompt", prompt] }

        try await ProcessRunner.run(binary, args, stderrTo: Paths.whisperLog)

        let txt = base.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: txt) }
        return try String(contentsOf: txt, encoding: .utf8)
    }
}

/// OpenAI-compatible /audio/transcriptions (Groq, OpenAI) and whisper.cpp's whisper-server.
struct APIWhisper: Transcriber {
    let endpoint: URL
    let key: String?
    let model: String
    let language: String
    let prompt: String

    func transcribe(wav: URL) async throws -> String {
        var form = Multipart()
        if !model.isEmpty { form.field("model", model) }
        form.field("response_format", "json")
        form.field("temperature", "0")
        if !language.isEmpty && language != "auto" { form.field("language", language) }
        if !prompt.isEmpty { form.field("prompt", prompt) }
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: try Data(contentsOf: wav))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await URLSession.shared.upload(for: request, from: form.finalized())
        try HTTP.check(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw MurmurError("Unexpected transcription response") }
        return text
    }
}

enum ProcessRunner {
    /// Runs a process to completion. Cancelling the surrounding Task terminates it (Esc).
    static func run(_ executable: URL, _ args: [String], stderrTo logURL: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardError = logHandle ?? FileHandle.nullDevice
        defer { try? logHandle?.close() }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        try Task.checkCancellation()
        guard status == 0 else {
            throw MurmurError("whisper-cli failed (exit \(status)) — see ~/.config/murmur/whisper.log")
        }
    }
}

enum TranscriptFilter {
    /// Strips Whisper's non-speech annotations ("[BLANK_AUDIO]", "(music)") and collapses whitespace.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"\((?:music|applause|laughter|laughs|silence|inaudible|blank[_ ]audio|noise)[^)]*\)"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
