import AppKit
import CoreGraphics

/// Puts text at the cursor of whatever app has focus. Needs Accessibility permission.
final class Inserter {
    func insert(_ text: String, using options: Config.Insert) {
        if options.method.lowercased() == "type" {
            typeText(text)
        } else {
            paste(text, restore: options.restoreClipboard, delayMs: options.restoreDelayMs)
        }
    }

    private func paste(_ text: String, restore: Bool, delayMs: Int) {
        let pasteboard = NSPasteboard.general
        let saved = restore ? snapshot(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if restore {
            // Convention that tells clipboard managers to ignore this short-lived entry.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        let ourChange = pasteboard.changeCount

        postKey(9, flags: .maskCommand) // 9 = kVK_ANSI_V

        guard let saved else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(100, delayMs))) {
            // If something else was copied in the meantime, leave it alone.
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Types Unicode text in small chunks. Works in apps that block paste; slower for long text.
    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        var chunk = ""

        func flush() {
            guard !chunk.isEmpty else { return }
            let units = Array(chunk.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            chunk = ""
            usleep(3_000)
        }

        for ch in text {
            if ch == "\n" || ch == "\r\n" {
                flush()
                postKey(36) // Return
                usleep(3_000)
                continue
            }
            chunk.append(ch)
            if chunk.utf16.count >= 16 { flush() }
        }
        flush()
    }
}
