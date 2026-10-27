# mac-tools

A collection of macOS menu bar applications, utility scripts, CLI monitors, and agent skills by [@mbtiongson1](https://github.com/mbtiongson1).

---

## Repository Structure

```text
mac-tools/
├── apps/
│   ├── DiskApp/              # Native macOS menu bar storage monitor & WinDirStat treemap launcher
│   │   ├── src/main.swift    # Swift Cocoa status bar app with live disk telemetry
│   │   ├── Info.plist        # Configured with LSUIElement=true (dock-hidden)
│   │   └── build.sh          # One-click build & install script (~/Applications/DiskApp.app)
│   ├── MacDashApp/           # Native macOS menu bar status dashboard (SwiftUI)
│   │   ├── src/main.swift    # CPU, RAM, SWAP, per-app memory, Network, Thermal popover monitor
│   │   ├── Info.plist        # Configured with LSUIElement=true (dock-hidden)
│   │   └── build.sh          # One-click build, install, & launch-at-login script
│   └── ToggleSleep/          # Native macOS menu bar app for toggling sleep/caffeine
│       ├── src/main.swift    # Swift Cocoa menu bar status item
│       ├── Info.plist        # Configured with LSUIElement=true (dock-hidden)
│       └── build.sh          # One-click build, install, & launch-at-login script
├── bin/
│   ├── disk                  # WinDirStat-style visual treemap & git analyzer launcher
│   └── toggle-sleep          # pmset wrapper script for disabling/enabling sleep
├── tools/
│   ├── disk/                 # WinDirStat-style terminal disk space & Git analyzer
│   │   ├── disk              # Launcher script
│   │   └── disk.py           # Python 2D cushion treemap engine & Git Radar
│   └── macdash/              # Live terminal-based macOS system dashboard
│       ├── macdash           # Launcher script
│       └── macdash.py        # Python TUI dashboard
└── skills/
    ├── disk/                 # Pi/Agent skill to run visual WinDirStat treemap & git analysis (/disk)
    ├── menu-bar/             # Pi/Agent skill to scaffold & install native menu bar apps
    ├── toggle-sleep/         # Pi/Agent skill to agentically query or toggle sleep states
    └── macdash/              # Pi/Agent skill to run macdash in Herdr / terminal
```

---

## Apps

### MacDash (Menu Bar App)
A native macOS status bar monitor (`~/Applications/MacDash.app`) built with SwiftUI:
- **Menu bar item**: CPU temperature in Celsius as the primary readout, followed by current swap used (for example, `76°C · 3.1 GB`) alongside a thermometer symbol.
- **Popover card**: A compact, two-column glanceable dashboard with large metrics and native Liquid Glass applied to icon glyphs only on macOS 26+ (with a tinted icon fallback on older macOS):
  - **CPU**: CPU temperature in Celsius prominently displayed (sampled via `macmon`), plus real-time CPU utilization and load averages with a color-coded activity ring.
  - **RAM**: Memory utilization (active, wired, compressor vs total physical RAM), plus app icons and top apps sorted by physical memory footprint.
  - **Storage**: Real root volume capacity, available/free space, and utilization percentage with semantic health ring.
  - **SWAP**: Absolute swap used with explicit macOS-managed dynamic virtual memory indication; avoids misleading capacity caps or pressure percentages.
  - **Network**: Real-time download & upload bandwidth rates with 60-sample, dynamically scaled sparklines, sampled from active non-loopback interfaces.
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

### DiskApp (Menu Bar App)
A native macOS status bar monitor (`~/Applications/DiskApp.app`) built with Swift and Cocoa:
- **Menu bar item**: Real-time available disk capacity (e.g. `💾 11.2 GB`) with drive icon.
- **Controls**:
  - Live storage utilization percentage and volume metrics.
  - One-click launch of the terminal visual cushion treemap (`disk ~` or `disk ~/Documents`).
- **Build & Install**:
  ```bash
  cd apps/DiskApp
  ./build.sh
  ```

---

## Tools

### disk
A visual WinDirStat-style disk space & Git repository analyzer for the macOS terminal:
- **WinDirStat Cushion Treemap**: 2D squarified ASCII/Unicode block map with color-coded cushions for directories and file types.
- **Git Radar**: Deep audit of `.git` directories, packfile sizes, loose objects, worktrees, and hygiene recommendations (`git gc --prune=now`).
- **Category breakdown**: Color-coded distribution for Git repos, Caches/Dependencies, Media, Images, Archives, Code, and Data.
- **Invocation**: Run `disk [path]`, `disk --json`, or use `/disk` inside the Pi agent harness.

### macdash
An interactive macOS system dashboard showing real-time CPU, RAM, disk, network, and battery statistics in the terminal.

---

## Skills

- **`skills/disk`**: Agent skill to render the visual WinDirStat treemap and provide intelligent disk space & Git repository diagnostics via `/disk`.
- **`skills/toggle-sleep`**: Agent skill to inspect current sleep status or toggle sleep mode (disable/enable) on demand.
- **`skills/menu-bar`**: Universal agent skill for scaffolding, compiling, and installing lightweight macOS menu bar utility apps with startup registration.
- **`skills/macdash`**: Agent skill to launch macdash in a visible Herdr multiplexer terminal pane.
