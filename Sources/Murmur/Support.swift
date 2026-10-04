import Foundation

/// Everything Murmur reads or writes lives in ~/.config/murmur.
enum Paths {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/murmur", isDirectory: true)
    static let config = dir.appendingPathComponent("config.json")
    static let env = dir.appendingPathComponent(".env")
    static let models = dir.appendingPathComponent("models", isDirectory: true)
    static let log = dir.appendingPathComponent("murmur.log")
    static let whisperLog = dir.appendingPathComponent("whisper.log")

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: env.path) {
            fm.createFile(atPath: env.path, contents: Data(envTemplate.utf8),
                          attributes: [.posixPermissions: 0o600])
        }
        // Keep the log from growing forever.
        if let size = (try? fm.attributesOfItem(atPath: log.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: log)
        }
    }

    private static let envTemplate = """
    # Murmur API keys. Leave blank to stay fully local/offline.
    # Used for cloud transcription (transcription.engine = groq/openai/auto)
    # and for transcript cleanup (cleanup.provider = groq/openai/anthropic/auto).
    GROQ_API_KEY=
    OPENAI_API_KEY=
    ANTHROPIC_API_KEY=

    """
}

/// Minimal .env reader. Values in ~/.config/murmur/.env win over the process
/// environment (apps launched from Finder don't inherit your shell env anyway).
struct Env {
    private var values: [String: String] = [:]

    static func load() -> Env {
        var env = Env()
        guard let text = try? String(contentsOf: Paths.env, encoding: .utf8) else { return env }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { env.values[key] = value }
        }
        return env
    }

    subscript(key: String) -> String? {
        if let v = values[key] { return v }
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        return nil
    }
}

struct MurmurError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Local-only log file. Records errors and timings, never transcript text.
enum Log {
    private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: Paths.log) {
            _ = handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Paths.log)
        }
    }
}

enum HTTP {
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw MurmurError("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw MurmurError("HTTP \(http.statusCode): \(body)")
        }
    }
}

struct Multipart {
    let boundary = "murmur-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
