---
name: menu-bar
description: Scaffold, build, install, and configure lightweight native macOS menu bar status apps with automatic login item/startup support.
version: 1.0.0
---

# menu-bar

Create, build, and configure native macOS menu bar apps (`LSUIElement = true`) in Swift, including automatic login item registration so they start on system boot.

## App Anatomy

Every menu bar app lives under `~/Applications/<AppName>.app`:
- `~/Applications/<AppName>.app/Contents/MacOS/<AppName>`
- `~/Applications/<AppName>.app/Contents/Info.plist`

### Standard Info.plist Template

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string><AppName></string>
    <key>CFBundleIdentifier</key>
    <string>com.marco.<AppName></string>
    <key>CFBundleName</key>
    <string><AppName></string>
    <key>CFBundleDisplayName</key>
    <string><AppName></string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```
Setting `<key>LSUIElement</key><true/>` ensures the app runs solely as a menu bar accessory without appearing in the macOS Dock or App Switcher (`Cmd + Tab`).

---

## Swift App Template

Create the Swift entry point:

```swift
import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "<AppName>")
            } else {
                button.title = "★"
            }
        }
        setupMenu()
    }

    func setupMenu() {
        let menu = NSMenu()
        
        let infoItem = NSMenuItem(title: "<AppName> Running", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Add custom actions
        let actionItem = NSMenuItem(title: "Perform Action", action: #selector(performAction), keyEquivalent: "a")
        actionItem.target = self
        menu.addItem(actionItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    @objc func performAction() {
        // Handle trigger or launch background tasks
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

---

## Build and Launch Workflow

1. **Compile**:
```bash
swiftc -O /tmp/<app-source>.swift -o ~/Applications/<AppName>.app/Contents/MacOS/<AppName>
```

2. **Add to Startup / Login Items**:
```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Users/marcotiongson/Applications/<AppName>.app", hidden:false, name:"<AppName>"}'
```

3. **Launch Immediately**:
```bash
killall <AppName> 2>/dev/null || true
open -a ~/Applications/<AppName>.app
```

4. **Verify**:
```bash
pgrep -fl <AppName>
```
