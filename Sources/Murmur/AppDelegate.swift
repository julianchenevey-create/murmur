import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private let menu = NSMenu()
    private var configError: String?

    private static let enabledKey = "enabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.bootstrap()
        let (config, error) = Config.load()
        configError = error

        controller = DictationController(config: config, env: Env.load())
        controller.onStateChange = { [weak self] _ in self?.refreshIcon() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        menuNeedsUpdate(menu)
        refreshIcon()

        Permissions.requestOnLaunch()
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        controller.setEnabled(enabled)
        if let error { controller.showError(error) }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(label("Murmur: \(statusText)"))
        menu.addItem(label("Hold \(controller.config.hotkey) to talk · double-tap for hands-free · Esc cancels"))
        if let configError { menu.addItem(label("⚠︎ \(configError)")) }
        menu.addItem(.separator())

        let enabled = action("Enabled", #selector(toggleEnabled), key: "e")
        enabled.state = controller.isEnabled ? .on : .off
        menu.addItem(enabled)

        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        if isBundled {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            login.isEnabled = false
            login.toolTip = "Only available when running Murmur.app (see scripts/build-app.sh)"
        }
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(action("Open Settings File", #selector(openSettings), key: ","))
        menu.addItem(action("Open .env (API Keys)", #selector(openEnv)))
        menu.addItem(action("Reload Settings", #selector(reloadSettings), key: "r"))
        menu.addItem(action("Show Config Folder", #selector(openFolder)))
        menu.addItem(.separator())

        let permissions = NSMenu()
        permissions.autoenablesItems = false
        permissions.addItem(permissionItem("Accessibility", Permissions.accessibility, "Privacy_Accessibility"))
        permissions.addItem(permissionItem("Input Monitoring", Permissions.inputMonitoring, "Privacy_ListenEvent"))
        permissions.addItem(permissionItem("Microphone", Permissions.microphone, "Privacy_Microphone"))
        let allGranted = Permissions.accessibility && Permissions.microphone
        let permissionsItem = NSMenuItem(title: allGranted ? "Permissions" : "⚠︎ Permissions Needed",
                                         action: nil, keyEquivalent: "")
        permissionsItem.submenu = permissions
        menu.addItem(permissionsItem)
        menu.addItem(.separator())

        menu.addItem(action("Quit Murmur", #selector(quit), key: "q"))
    }

    private var statusText: String {
        switch controller.state {
        case .disabled: return "Off"
        case .waitingForPermission: return "Waiting for Accessibility permission"
        case .idle: return "Ready"
        case .recordingHold: return "Listening"
        case .recordingHandsFree: return "Listening (hands-free)"
        case .processing: return "Transcribing"
        }
    }

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func permissionItem(_ name: String, _ granted: Bool, _ pane: String) -> NSMenuItem {
        let item = action("\(granted ? "✓" : "✗") \(name)…", #selector(openPermissionPane(_:)))
        item.representedObject = pane
        return item
    }

    private func refreshIcon() {
        let symbol: String
        switch controller.state {
        case .disabled: symbol = "mic.slash"
        case .waitingForPermission: symbol = "exclamationmark.triangle"
        case .idle: symbol = "waveform"
        case .recordingHold, .recordingHandsFree: symbol = "mic.fill"
        case .processing: symbol = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        let enable = !controller.isEnabled
        controller.setEnabled(enable)
        UserDefaults.standard.set(enable, forKey: Self.enabledKey)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            Log.write("launch at login: \(error)")
            controller.showError("Couldn't change login item: \(error.localizedDescription)")
        }
    }

    @objc private func openSettings() { openInTextEditor(Paths.config) }
    @objc private func openEnv() { openInTextEditor(Paths.env) }
    @objc private func openFolder() { NSWorkspace.shared.activateFileViewerSelecting([Paths.config]) }

    @objc private func reloadSettings() {
        let (config, error) = Config.load()
        configError = error
        controller.reload(config: config, env: Env.load())
        if let error { controller.showError(error) }
    }

    @objc private func openPermissionPane(_ sender: NSMenuItem) {
        if let pane = sender.representedObject as? String { Permissions.openSettings(pane) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func openInTextEditor(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            if url == Paths.config { _ = Config.load() } else { Paths.bootstrap() }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-t", url.path] // default text editor
        try? process.run()
    }
}
