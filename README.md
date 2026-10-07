# mac-tools

A collection of macOS menu bar applications, utility scripts, CLI monitors, and agent skills by [@mbtiongson1](https://github.com/mbtiongson1).

---

## Repository Structure

```text
mac-tools/
├── apps/
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
    └── macdash/              # Pi/Agent skill to run macdash in Herdr / terminal
```

---

## Apps

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

- **`skills/menu-bar`**: Universal agent skill for scaffolding, compiling, and installing lightweight macOS menu bar utility apps with startup registration.
- **`skills/macdash`**: Agent skill to launch macdash in a visible Herdr multiplexer terminal pane.
