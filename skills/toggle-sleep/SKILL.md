---
name: toggle-sleep
description: Disable or re-enable macOS system sleep immediately, including when the lid is closed.
version: 1.1.0
---

# toggle-sleep

Agentically manage and toggle macOS system sleep states via `pmset` / `toggle-sleep`.

## Quick Actions

### 1. Disable System Sleep (Keep Awake / Caffeinate)
Prevents macOS from sleeping even when lid is closed or idle:

```bash
osascript -e 'do shell script "/Users/marcotiongson/bin/toggle-sleep 0" with administrator privileges'
```

If passwordless `sudo` is configured:
```bash
sudo -n /Users/marcotiongson/bin/toggle-sleep 0
```

### 2. Enable System Sleep (Restore Normal Sleep)
Restores normal system sleep behavior:

```bash
osascript -e 'do shell script "/Users/marcotiongson/bin/toggle-sleep 1" with administrator privileges'
```

If passwordless `sudo` is configured:
```bash
sudo -n /Users/marcotiongson/bin/toggle-sleep 1
```

### 3. Check Current Sleep Status
Query current state without requiring admin privileges:

```bash
pmset -g | awk '$1 == "SleepDisabled" { print ($2 == "1" ? "Sleep is DISABLED (Awake)" : "Sleep is ENABLED (Normal)") }'
```
