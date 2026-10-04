import Cocoa
import CoreGraphics

enum HotkeySpec {
    /// A lone modifier key (fn, right option, ...). `mask` is the device-specific flag bit,
    /// so left and right variants are told apart.
    case modifier(keyCode: CGKeyCode, mask: UInt64)
    /// A regular key plus required modifiers. These key events are swallowed so they don't type.
    case combo(keyCode: CGKeyCode, modifiers: CGEventFlags)

    static let fn = HotkeySpec.modifier(keyCode: 63, mask: CGEventFlags.maskSecondaryFn.rawValue)

    var isModifierOnly: Bool {
        if case .modifier = self { return true }
        return false
    }

    static func parse(_ raw: String) -> HotkeySpec? {
        let s = raw.lowercased().replacingOccurrences(of: " ", with: "")
        // Device-dependent masks from IOKit's NX_DEVICE*KEYMASK.
        let modifierKeys: [String: (CGKeyCode, UInt64)] = [
            "fn": (63, CGEventFlags.maskSecondaryFn.rawValue), "globe": (63, CGEventFlags.maskSecondaryFn.rawValue),
            "leftcontrol": (59, 0x01), "leftctrl": (59, 0x01),
            "rightcontrol": (62, 0x2000), "rightctrl": (62, 0x2000),
            "leftshift": (56, 0x02), "rightshift": (60, 0x04),
            "leftcommand": (55, 0x08), "leftcmd": (55, 0x08),
            "rightcommand": (54, 0x10), "rightcmd": (54, 0x10),
            "leftoption": (58, 0x20), "leftalt": (58, 0x20),
            "rightoption": (61, 0x40), "rightalt": (61, 0x40),
        ]
        if let m = modifierKeys[s] { return .modifier(keyCode: m.0, mask: m.1) }

        let parts = s.split(separator: "+").map(String.init)
        guard let keyName = parts.last, let code = keyCodes[keyName] else { return nil }
        var mods: CGEventFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": mods.insert(.maskCommand)
            case "ctrl", "control": mods.insert(.maskControl)
            case "opt", "option", "alt": mods.insert(.maskAlternate)
            case "shift": mods.insert(.maskShift)
            default: return nil
            }
        }
        return .combo(keyCode: code, modifiers: mods)
    }

    // ANSI virtual key codes (Carbon kVK_*).
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]
}

/// Global keyboard watcher built on a CGEventTap.
///
/// Everything except a combo hotkey's own key events is passed through untouched, so Esc
/// (and every other key) still reaches the focused app. Callbacks run on the main thread,
/// deferred until after the tap callback returns so the tap itself never stalls typing.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Any other key pressed (used to abort when a modifier hotkey is part of a shortcut like fn+F1).
    var onOtherKey: (() -> Void)?

    let spec: HotkeySpec
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var modifierDown = false
    private var comboDown = false

    init(spec: HotkeySpec) { self.spec = spec }
    deinit { stop() }

    /// Fails if Accessibility permission hasn't been granted yet.
    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        modifierDown = false
        comboDown = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch spec {
        case let .modifier(code, mask):
            if type == .flagsChanged && keyCode == code {
                let down = event.flags.rawValue & mask != 0
                if down && !modifierDown {
                    modifierDown = true
                    fire(onPress)
                } else if !down && modifierDown {
                    modifierDown = false
                    fire(onRelease)
                }
                return pass
            }

        case let .combo(code, modifiers):
            if keyCode == code && (type == .keyDown || type == .keyUp) {
                if type == .keyDown {
                    if comboDown { return nil } // swallow auto-repeat
                    let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                    let held = CGEventFlags(rawValue: event.flags.rawValue & relevant.rawValue)
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if held == modifiers && !isRepeat {
                        comboDown = true
                        fire(onPress)
                        return nil
                    }
                } else if comboDown {
                    comboDown = false
                    fire(onRelease)
                    return nil
                }
            }
        }

        if type == .keyDown {
            fire(keyCode == 53 ? onEscape : onOtherKey) // 53 = kVK_Escape
        }
        return pass
    }

    private func fire(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
