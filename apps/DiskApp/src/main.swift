import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatus()

        // Refresh every 30 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func getDiskInfo() -> (freeGB: Double, totalGB: Double, percentUsed: Double) {
        let fileURL = URL(fileURLWithPath: "/")
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            if let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity {
                let freeGB = Double(free) / 1_073_741_824.0
                let totalGB = Double(total) / 1_073_741_824.0
                let percentUsed = ((totalGB - freeGB) / totalGB) * 100.0
                return (freeGB, totalGB, percentUsed)
            }
        } catch {}
        return (0, 0, 0)
    }

    func updateStatus() {
        guard let button = statusItem?.button else { return }
        let (freeGB, totalGB, percentUsed) = getDiskInfo()

        let icon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Disk")
        icon?.isTemplate = true
        button.image = icon
        button.imagePosition = .imageLeading
        button.title = String(format: " %.1f GB", freeGB)

        let menu = NSMenu()

        // Header Title
        let titleItem = NSMenuItem(title: "Disk Space & Git Treemap (/disk)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        // Capacity summary
        let capStr = String(format: "Storage: %.1f%% Used (%.1f GB Free / %.1f GB)", percentUsed, freeGB, totalGB)
        let capItem = NSMenuItem(title: capStr, action: nil, keyEquivalent: "")
        capItem.isEnabled = false
        menu.addItem(capItem)
        menu.addItem(NSMenuItem.separator())

        // Actions
        let scanHomeItem = NSMenuItem(title: "Launch Visual Treemap (~)", action: #selector(scanHome), keyEquivalent: "t")
        scanHomeItem.target = self
        menu.addItem(scanHomeItem)

        let scanDocsItem = NSMenuItem(title: "Scan ~/Documents", action: #selector(scanDocuments), keyEquivalent: "d")
        scanDocsItem.target = self
        menu.addItem(scanDocsItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc func scanHome() {
        launchTerminal(command: "disk ~")
    }

    @objc func scanDocuments() {
        launchTerminal(command: "disk ~/Documents")
    }

    @objc func refresh() {
        updateStatus()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    func launchTerminal(command: String) {
        let script = "tell application \"Terminal\" to do script \"\(command)\"; activate application \"Terminal\""
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
