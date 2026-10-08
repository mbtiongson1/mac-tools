# mac-tools

A collection of macOS menu bar applications, utility scripts, CLI monitors, and agent skills by [@mbtiongson1](https://github.com/mbtiongson1).

---

## Repository Structure

```text
mac-tools/
├── apps/
│   ├── MacDashApp/           # Native macOS menu bar status dashboard (SwiftUI)
│   │   ├── src/main.swift    # CPU, RAM, SWAP, per-app memory, Network, Thermal popover monitor
│   │   ├── Info.plist        # Configured with LSUIElement=true (dock-hidden)
│   │   └── build.sh          # One-click build, install, & launch-at-login script
│   └── ToggleSleep/          # Native macOS menu bar app for toggling sleep/caffeine
│       ├── src/main.swift    # Swift Cocoa menu bar status item
│       ├── Info.plist        # Configured with LSUIElement=true (dock-hidden)
│       └── build.sh          # One-click build, install, & launch-at-login script
├── bin/
│   └── toggle-sleep          # pmset wrapper script for disabling/enabling sleep
├── tools/
│   └── macdash/              # Live terminal-based macOS system dashboard
│       ├── macdash           # Launcher script
│       └── macdash.py        # Python TUI dashboard
└── skills/
    ├── menu-bar/             # Pi/Agent skill to scaffold & install native menu bar apps
    ├── toggle-sleep/         # Pi/Agent skill to agentically query or toggle sleep states
    └── macdash/              # Pi/Agent skill to run macdash in Herdr / terminal
```

---

## Apps

### MacDash (Menu Bar App)
A native macOS status bar monitor (`~/Applications/MacDash.app`) built with SwiftUI:
- **Menu bar item**: Live text displaying `CPU % · RAM %` alongside SF Symbol `gauge.badge.bolt`.
- **Popover card**: A compact, two-column glanceable dashboard with large metrics and native Liquid Glass applied to icon glyphs only on macOS 26+ (with a tinted icon fallback on older macOS):
  - **CPU**: Real-time system CPU percentage & load averages, with a color-coded activity ring.
  - **RAM**: Memory utilization (active, wired, compressor vs total physical RAM), plus app icons and top apps sorted by physical memory footprint.
  - **SWAP**: Absolute swap used and available capacity; avoids presenting allocated swap capacity as a misleading pressure percentage.
  - **Network**: Real-time download & upload bandwidth rates sampled from active non-loopback interfaces.
  - **Thermal Condition**: Apple Silicon thermal state and uptime in a compact status capsule.
  - **Uptime**: System uptime clock.
  - **Quick Actions**: Force-quit an app after inline confirmation, or open Activity Monitor.
- **Build & Install**:
  ```bash
  cd apps/MacDashApp
  ./build.sh
  ```

### ToggleSleep
A native macOS status bar menu app (`~/Applications/ToggleSleep.app`):
- **Visual status**:
  - ☕ (`cup.and.saucer.fill`): Awake (sleep disabled)
  - 🌙 (`moon.zzz.fill`): Normal sleep permitted
- **Controls**:
  - Click menu to toggle sleep mode immediately via `pmset` / `toggle-sleep`.
  - Configured with automatic Launch at Login (starts up on boot).
- **Build & Install**:
  ```bash
  cd apps/ToggleSleep
  ./build.sh
  ```

---

## Tools

### macdash
An interactive macOS system dashboard showing real-time CPU, RAM, disk, network, and battery statistics in the terminal.

---

## Skills

- **`skills/toggle-sleep`**: Agent skill to inspect current sleep status or toggle sleep mode (disable/enable) on demand.
- **`skills/menu-bar`**: Universal agent skill for scaffolding, compiling, and installing lightweight macOS menu bar utility apps with startup registration.
- **`skills/macdash`**: Agent skill to launch macdash in a visible Herdr multiplexer terminal pane.
