import Foundation

/// Settings file: ~/.config/murmur/config.json (comments and trailing commas allowed).
/// Any key you leave out falls back to the default below.
struct Config: Codable {
    /// "fn", "rightOption", "rightCommand", "rightControl", "rightShift", "leftOption", ...
    /// or a combo such as "ctrl+option+space" / "cmd+shift+d" / "f13".
    var hotkey = "fn"
    /// A press shorter than this counts as a tap (for double-tap detection), not a dictation.
    var tapThresholdMs = 250
    /// Max gap between the first tap's release and the second press.
    var doubleTapWindowMs = 400
    /// Hands-free sessions stop automatically after this long.
    var handsFreeMaxSeconds = 300
    /// What happens at the hands-free limit: "transcribe" or "discard".
    var handsFreeTimeoutAction = "transcribe"
    var showPill = true

    var transcription = Transcription()
    var cleanup = Cleanup()
    var insert = Insert()

    struct Transcription: Codable {
        /// "local" (whisper.cpp), "groq", "openai", or "auto" (API if a key exists in .env, else local).
        var engine = "local"
        /// ISO code like "en", "de", or "auto" to detect. Use a non-.en model for anything but English.
        var language = "en"
        /// Empty = look in /opt/homebrew/bin and /usr/local/bin.
        var whisperCliPath = ""
        var modelPath = "~/.config/murmur/models/ggml-small.en.bin"
        /// 0 = let whisper.cpp decide.
        var threads = 0
        /// Optional: URL of a running `whisper-server` (e.g. "http://127.0.0.1:8178").
        /// Keeps the model loaded in memory, so local transcription starts faster.
        var serverURL = ""
        var groqModel = "whisper-large-v3-turbo"
        var openaiModel = "whisper-1"
        /// Names and jargon that Whisper should spell correctly, e.g. "Kubernetes, Murmur, Priya".
        var vocabulary = ""
    }

    struct Cleanup: Codable {
        /// "auto" (first key found: groq, openai, anthropic), "groq", "openai", "anthropic",
        /// "ollama" (local, offline), or "none" to paste the raw transcript.
        var provider = "auto"
        /// "sentence" (normal prose) or "casual" (lowercase, light punctuation, like texting).
        var style = "sentence"
        /// Appended to the system prompt, e.g. "Use British spelling."
        var extraInstructions = ""
        var groqModel = "llama-3.1-8b-instant"
        var openaiModel = "gpt-4.1-mini"
        var anthropicModel = "claude-haiku-4-5"
        var ollamaModel = "llama3.2:3b"
        var ollamaURL = "http://localhost:11434"
        /// If cleanup takes longer than this, the raw transcript is pasted instead.
        var timeoutSeconds = 8.0
    }

    struct Insert: Codable {
        /// "paste" (pasteboard + Cmd-V) or "type" (simulated keystrokes; slower, leaves clipboard alone).
        var method = "paste"
        /// false: the transcript stays on the clipboard so you can paste it again.
        /// true: your previous clipboard comes back after the paste.
        var restoreClipboard = false
        var restoreDelayMs = 500
        /// Add a space after the inserted text so consecutive dictations don't run together.
        var trailingSpace = false
    }

    /// Returns the merged config plus a human-readable error if the file couldn't be used.
    static func load() -> (Config, String?) {
        let defaults = Config()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let defaultData = try? encoder.encode(defaults) else { return (defaults, nil) }

        guard FileManager.default.fileExists(atPath: Paths.config.path) else {
            try? defaultData.write(to: Paths.config)
            return (defaults, nil)
        }
        do {
            let userData = try Data(contentsOf: Paths.config)
            guard let user = try JSONSerialization.jsonObject(with: userData, options: [.json5Allowed]) as? [String: Any],
                  let base = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
            else { throw MurmurError("top level must be a JSON object") }
            let merged = try JSONSerialization.data(withJSONObject: merge(base, user))
            return (try JSONDecoder().decode(Config.self, from: merged), nil)
        } catch {
            Log.write("config.json unusable, using defaults: \(error)")
            return (defaults, "config.json has an error, using defaults (see murmur.log)")
        }
    }

    private static func merge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in override {
            if let b = base[key] as? [String: Any], let o = value as? [String: Any] {
                out[key] = merge(b, o)
            } else {
                out[key] = value
            }
        }
        return out
    }
}
