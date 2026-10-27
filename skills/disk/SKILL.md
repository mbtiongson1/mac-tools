---
name: disk
description: "Visual WinDirStat-style disk space & git repository analyzer for macOS terminal. Inspects any directory, renders a 2D cushion treemap with color-coded cushions, pinpoints bloated .git repositories, loose objects, packfiles, node_modules, and caches, and provides actionable disk reclamation advice. Triggers on /disk, disk, 'check disk', 'what is taking up space', 'git bloat'."
---

# /disk

A visual WinDirStat-style disk space and Git repository analyzer running natively in the macOS terminal. Renders a proportional 2D cushion treemap, category distribution bars, hierarchical space hogs tables, and a specialized **Git Radar** with actionable reclamation recommendations.

---

## When to Use

- User invokes `/disk` or `/disk [path]`
- User asks "what is taking up space on my Mac?"
- User asks to inspect Git repositories for bloat (`.git`, loose objects, packfiles, worktrees)
- User wants a WinDirStat, GrandPerspective, or ncdu visual breakdown directly inside the terminal window

---

## Execution Protocol

### Step 1: Run the `disk` Terminal Engine

Execute the `disk` CLI binary on the target path (defaults to current working directory or user-specified folder):

```bash
disk "${TARGET_PATH:-.}"
```

For programmatic evaluation or deep inspection, run with `--json`:
```bash
disk "${TARGET_PATH:-.}" --json
```

### Step 2: Display the Visual Terminal Output

Present the raw visual terminal rendering verbatim so the user sees:
1. **System Capacity Banner**: Volume mount, total/used/free space, and capacity percentage bar.
2. **WinDirStat Cushion Treemap**: 2D squarified ASCII/Unicode colored cushion map with inscribed directory and file labels.
3. **File Type Distribution**: Proportional stacked color bar and category legend (Git 🔴, Cache/Venv 🟡, Media 🟣, Images 🟢, Archives 🟠, Code 🔵, Data ⚪).
4. **Top Space Consumers Table**: Rank, category badge, human-readable size, file count, percentage bar, and paths.
5. **Git Repository Radar**: Deep audit of every `.git` folder (packed objects vs unpruned loose objects, packfiles, active worktrees, and health status).

### Step 3: Provide Agentic Space & Git Analysis

After displaying the visual snapshot, provide an intelligent analytical summary:

1. **Storage Margin Assessment**:
   - Evaluate available disk capacity. If >90% used, warn about APFS performance degradation and memory swap starvation.
2. **Git Repository Diagnostics**:
   - Specifically audit any `.git` folders detected.
   - If loose object count > 500 or loose size > 20 MB: advise running `git -C <path> gc --prune=now`.
   - If multiple active worktrees exist: check for abandoned worktree checkouts.
   - If `.git` history is disproportionately large compared to active source code: identify historical binaries or large packfiles.
3. **Ephemeral & Cache Waste**:
   - Identify re-creatable artifacts: inactive Python `.venv`, abandoned `node_modules`, Swift `.build`, Xcode `DerivedData`, or `__pycache__`.
4. **Actionable Remediation Commands**:
   - Provide exact, safe, copy-pasteable bash commands with estimated disk space reclaimed.
