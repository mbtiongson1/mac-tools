import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let toggleScriptPath = "/Users/marcotiongson/bin/toggle-sleep"
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        updateStatus()
        setupMenu()
        
        // Periodic check in case pmset changed externally
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func isSleepDisabled() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    if parts.count >= 2 && parts[0] == "SleepDisabled" {
                        return parts[1] == "1"
                    }
                }
            }
        } catch {
            // ignore
        }
        return false
    }

    func updateStatus() {
        guard let button = statusItem.button else { return }
        let disabled = isSleepDisabled()
        
        DispatchQueue.main.async {
            if disabled {
                if #available(macOS 11.0, *) {
                    button.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Sleep Disabled (Awake)")
                } else {
                    button.title = "☕"
                }
                button.toolTip = "Toggle Sleep: Keeping awake (Sleep Disabled)"
            } else {
                if #available(macOS 11.0, *) {
                    button.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "Sleep Allowed")
                } else {
                    button.title = "🌙"
                }
                button.toolTip = "Toggle Sleep: Normal sleep allowed"
            }
            self.setupMenu()
        }
    }

    func setupMenu() {
        let menu = NSMenu()
        
        let disabled = isSleepDisabled()
        let statusText = disabled ? "Status: Awake (Sleep Disabled)" : "Status: Normal Sleep Allowed"
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleTitle = disabled ? "Enable Sleep (Normal)" : "Keep Awake (Disable Sleep)"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleAction), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let startupItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleStartup), keyEquivalent: "")
        startupItem.target = self
        startupItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(startupItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    @objc func toggleAction() {
        let currentlyDisabled = isSleepDisabled()
        let arg = currentlyDisabled ? "1" : "0" // 0 disables sleep, 1 enables sleep in script
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Try passwordless sudo first
            let sudoTask = Process()
            sudoTask.launchPath = "/usr/bin/sudo"
            sudoTask.arguments = ["-n", self.toggleScriptPath, arg]
            
            do {
                try sudoTask.run()
                sudoTask.waitUntilExit()
                if sudoTask.terminationStatus == 0 {
                    self.updateStatus()
                    return
                }
            } catch {
                // fall back to osascript with admin privileges
            }

            // Fallback: prompt via osascript
            let script = "do shell script \"\(self.toggleScriptPath) \(arg)\" with administrator privileges"
            let osaTask = Process()
            osaTask.launchPath = "/usr/bin/osascript"
            osaTask.arguments = ["-e", script]
            do {
                try osaTask.run()
                osaTask.waitUntilExit()
            } catch {
                // Failed
            }
            
            self.updateStatus()
        }
    }

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func toggleStartup(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    sender.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    sender.state = .on
                }
            } catch {
                print("Failed to toggle login item: \(error)")
            }
        }
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // hides from dock
app.run()
