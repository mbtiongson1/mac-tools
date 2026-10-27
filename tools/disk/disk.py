#!/usr/bin/env python3
"""
disk - A visual WinDirStat-style disk space & git repository analyzer for macOS terminal.
Renders an interactive or snapshot 2D cushion treemap, detects bloated .git repositories,
analyzes loose objects/packfiles/worktrees, and suggests actionable space reclamation.
Part of the mac-tools suite.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ANSI styling constants
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
UNDERLINE = "\033[4m"

# 256-color palette matching WinDirStat categories
COLOR_GIT = "\033[38;5;196m"      # Bright Crimson / Red
COLOR_CACHE = "\033[38;5;220m"    # Gold / Amber
COLOR_MEDIA = "\033[38;5;141m"    # Purple / Lavender
COLOR_IMAGE = "\033[38;5;42m"     # Emerald Green
COLOR_ARCHIVE = "\033[38;5;208m"  # Coral Orange
COLOR_CODE = "\033[38;5;51m"      # Cyan / Sky Blue
COLOR_DATA = "\033[38;5;253m"     # Ice White
COLOR_OTHER = "\033[38;5;244m"    # Muted Slate
COLOR_BORDER = "\033[38;5;238m"   # Dark Gray Border
COLOR_BG_DARK = "\033[48;5;235m"  # Dark subtle cell bg

BG_GIT = "\033[48;5;52m"
BG_CACHE = "\033[48;5;58m"
BG_MEDIA = "\033[48;5;54m"
BG_IMAGE = "\033[48;5;22m"
BG_ARCHIVE = "\033[48;5;94m"
BG_CODE = "\033[48;5;24m"
BG_DATA = "\033[48;5;237m"
BG_OTHER = "\033[48;5;234m"

CATEGORIES = {
    "git": {
        "name": "Git Repos & Packs",
        "color": COLOR_GIT,
        "bg": BG_GIT,
        "badge": "GIT",
        "char": "█",
    },
    "cache": {
        "name": "Caches & Dependencies",
        "color": COLOR_CACHE,
        "bg": BG_CACHE,
        "badge": "CACHE",
        "char": "█",
    },
    "media": {
        "name": "Video & Audio",
        "color": COLOR_MEDIA,
        "bg": BG_MEDIA,
        "badge": "MEDIA",
        "char": "█",
    },
    "image": {
        "name": "Images & Artwork",
        "color": COLOR_IMAGE,
        "bg": BG_IMAGE,
        "badge": "IMAGE",
        "char": "█",
    },
    "archive": {
        "name": "Archives & Installers",
        "color": COLOR_ARCHIVE,
        "bg": BG_ARCHIVE,
        "badge": "ARCHIVE",
        "char": "█",
    },
    "code": {
        "name": "Code & Scripts",
        "color": COLOR_CODE,
        "bg": BG_CODE,
        "badge": "CODE",
        "char": "█",
    },
    "data": {
        "name": "Documents & Databases",
        "color": COLOR_DATA,
        "bg": BG_DATA,
        "badge": "DATA",
        "char": "█",
    },
    "other": {
        "name": "Other Files",
        "color": COLOR_OTHER,
        "bg": BG_OTHER,
        "badge": "OTHER",
        "char": "█",
    },
}

EXT_MAP = {
    # Media
    ".mp4": "media", ".mov": "media", ".mkv": "media", ".avi": "media",
    ".webm": "media", ".mp3": "media", ".wav": "media", ".aac": "media",
    ".flac": "media", ".m4a": "media", ".m4v": "media", ".ogg": "media",
    # Images
    ".png": "image", ".jpg": "image", ".jpeg": "image", ".gif": "image",
    ".webp": "image", ".svg": "image", ".psd": "image", ".ai": "image",
    ".tiff": "image", ".bmp": "image", ".heic": "image", ".ico": "image",
    # Archives
    ".zip": "archive", ".tar": "archive", ".gz": "archive", ".tgz": "archive",
    ".bz2": "archive", ".xz": "archive", ".7z": "archive", ".rar": "archive",
    ".dmg": "archive", ".pkg": "archive", ".iso": "archive",
    # Code
    ".py": "code", ".ts": "code", ".tsx": "code", ".js": "code", ".jsx": "code",
    ".swift": "code", ".rs": "code", ".go": "code", ".c": "code", ".cpp": "code",
    ".h": "code", ".hpp": "code", ".java": "code", ".kt": "code", ".sh": "code",
    ".zsh": "code", ".bash": "code", ".rb": "code", ".php": "code", ".css": "code",
    ".scss": "code", ".html": "code", ".vue": "code", ".svelte": "code",
    # Data & Docs
    ".pdf": "data", ".sqlite": "data", ".db": "data", ".json": "data",
    ".csv": "data", ".tsv": "data", ".parquet": "data", ".xlsx": "data",
    ".docx": "data", ".pptx": "data", ".md": "data", ".txt": "data",
    ".yaml": "data", ".yml": "data", ".toml": "data", ".xml": "data",
}

CACHE_DIR_NAMES = {
    "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache",
    ".build", "target", "dist", "DerivedData", "Pods", ".gradle",
    ".cargo", ".parcel-cache", ".next", ".nuxt", ".turbo", ".cache",
}


def human_size(bytes_val: float) -> str:
    """Format bytes into readable unit (B, KiB, MiB, GiB, TiB)."""
    if bytes_val < 1024:
        return f"{int(bytes_val)} B"
    for unit in ["KiB", "MiB", "GiB", "TiB"]:
        bytes_val /= 1024.0
        if bytes_val < 1024.0 or unit == "TiB":
            return f"{bytes_val:.1f} {unit}"
    return f"{bytes_val:.1f} PiB"


def classify_file(path_str: str) -> str:
    """Classify a file into one of the top-level categories."""
    parts = path_str.split(os.sep)
    if ".git" in parts or path_str.endswith(".git") or "/.git/" in path_str:
        return "git"
    for part in parts:
        if part in CACHE_DIR_NAMES:
            return "cache"
    _, ext = os.path.splitext(path_str)
    ext_lower = ext.lower()
    return EXT_MAP.get(ext_lower, "other")


@dataclass
class GitRepoInfo:
    root: str
    total_size: int = 0
    pack_size: int = 0
    pack_count: int = 0
    loose_size: int = 0
    loose_count: int = 0
    worktrees_count: int = 0
    worktrees_size: int = 0
    branches_count: int = 0
    status_summary: str = "Healthy"
    recommendation: Optional[str] = None


@dataclass
class ScanNode:
    name: str
    path: str
    size: int = 0
    file_count: int = 0
    is_dir: bool = True
    category: str = "other"
    children: List[ScanNode] = field(default_factory=list)


def inspect_git_repository(git_dir: str) -> GitRepoInfo:
    """Inspect the internal layout of a .git directory."""
    repo_root = os.path.dirname(os.path.abspath(git_dir))
    info = GitRepoInfo(root=repo_root)

    # 1. Pack files
    pack_dir = os.path.join(git_dir, "objects", "pack")
    if os.path.isdir(pack_dir):
        try:
            for entry in os.scandir(pack_dir):
                if entry.is_file():
                    sz = entry.stat().st_size
                    info.pack_size += sz
                    if entry.name.endswith(".pack"):
                        info.pack_count += 1
        except OSError:
            pass

    # 2. Loose objects
    obj_dir = os.path.join(git_dir, "objects")
    if os.path.isdir(obj_dir):
        try:
            for entry in os.scandir(obj_dir):
                if entry.is_dir() and len(entry.name) == 2:
                    try:
                        for f in os.scandir(entry.path):
                            if f.is_file():
                                info.loose_size += f.stat().st_size
                                info.loose_count += 1
                    except OSError:
                        pass
        except OSError:
            pass

    # 3. Worktrees
    wt_dir = os.path.join(git_dir, "worktrees")
    if os.path.isdir(wt_dir):
        try:
            for entry in os.scandir(wt_dir):
                if entry.is_dir():
                    info.worktrees_count += 1
                    try:
                        for root, _, files in os.walk(entry.path):
                            for f in files:
                                info.worktrees_size += os.path.getsize(os.path.join(root, f))
                    except OSError:
                        pass
        except OSError:
            pass

    # 4. Total .git size
    try:
        for root, _, files in os.walk(git_dir):
            for f in files:
                try:
                    info.total_size += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    except OSError:
        pass

    # 5. Evaluate Health Status
    if info.loose_count > 1000 or info.loose_size > 50 * 1024 * 1024:
        info.status_summary = "Needs GC (Loose objects)"
        info.recommendation = f"git -C '{repo_root}' gc --prune=now"
    elif info.worktrees_count > 3:
        info.status_summary = f"Multi-Worktrees ({info.worktrees_count})"
        info.recommendation = f"git -C '{repo_root}' worktree prune"
    elif info.total_size > 300 * 1024 * 1024:
        info.status_summary = "Large / Bloated History"
        info.recommendation = f"git -C '{repo_root}' gc --prune=now --aggressive"
    else:
        info.status_summary = "Lean & Packed"
        info.recommendation = None

    return info


class DiskScanner:
    def __init__(self, target_path: str, max_depth: int = 4):
        self.target_path = os.path.abspath(os.path.expanduser(target_path))
        self.max_depth = max_depth
        self.total_size = 0
        self.total_files = 0
        self.category_sizes: Dict[str, int] = defaultdict(int)
        self.category_counts: Dict[str, int] = defaultdict(int)
        self.git_repos: List[GitRepoInfo] = []
        self.root_node: Optional[ScanNode] = None

    def scan(self) -> None:
        """Execute scan of directory hierarchy."""
        self.root_node = self._scan_dir(self.target_path, current_depth=0)
        self.total_size = self.root_node.size
        self.total_files = self.root_node.file_count

    def _scan_dir(self, dir_path: str, current_depth: int) -> ScanNode:
        name = os.path.basename(dir_path) or dir_path
        node = ScanNode(name=name, path=dir_path, is_dir=True)
        dir_cat_sizes: Dict[str, int] = defaultdict(int)

        # Check if this directory itself is a .git repository
        git_sub = os.path.join(dir_path, ".git")
        if os.path.isdir(git_sub):
            git_info = inspect_git_repository(git_sub)
            self.git_repos.append(git_info)

        try:
            entries = list(os.scandir(dir_path))
        except (PermissionError, FileNotFoundError, OSError):
            return node

        for entry in entries:
            try:
                # Do not follow symlinks to avoid infinite loops or counting external drives
                if entry.is_symlink():
                    continue

                if entry.is_file():
                    sz = entry.stat().st_size
                    node.size += sz
                    node.file_count += 1
                    cat = classify_file(entry.path)
                    dir_cat_sizes[cat] += sz
                    self.category_sizes[cat] += sz
                    self.category_counts[cat] += 1
                    if current_depth < self.max_depth:
                        child = ScanNode(
                            name=entry.name,
                            path=entry.path,
                            size=sz,
                            file_count=1,
                            is_dir=False,
                            category=cat,
                        )
                        node.children.append(child)

                elif entry.is_dir():
                    # Handle .git specially to avoid scanning thousands of tiny loose objects individually
                    if entry.name == ".git":
                        git_sz = 0
                        git_files = 0
                        for root, _, files in os.walk(entry.path):
                            for f in files:
                                try:
                                    f_sz = os.path.getsize(os.path.join(root, f))
                                    git_sz += f_sz
                                    git_files += 1
                                    self.category_sizes["git"] += f_sz
                                    self.category_counts["git"] += 1
                                except OSError:
                                    pass
                        node.size += git_sz
                        node.file_count += git_files
                        dir_cat_sizes["git"] += git_sz
                        git_node = ScanNode(
                            name=".git",
                            path=entry.path,
                            size=git_sz,
                            file_count=git_files,
                            is_dir=True,
                            category="git",
                        )
                        node.children.append(git_node)

                    # Handle common heavy cache folders without deep descent if at max_depth
                    elif entry.name in CACHE_DIR_NAMES and current_depth >= 2:
                        cache_sz = 0
                        cache_files = 0
                        for root, _, files in os.walk(entry.path):
                            for f in files:
                                try:
                                    f_sz = os.path.getsize(os.path.join(root, f))
                                    cache_sz += f_sz
                                    cache_files += 1
                                    cat = classify_file(os.path.join(root, f))
                                    self.category_sizes[cat] += f_sz
                                    self.category_counts[cat] += 1
                                except OSError:
                                    pass
                        node.size += cache_sz
                        node.file_count += cache_files
                        dir_cat_sizes["cache"] += cache_sz
                        cache_node = ScanNode(
                            name=entry.name,
                            path=entry.path,
                            size=cache_sz,
                            file_count=cache_files,
                            is_dir=True,
                            category="cache",
                        )
                        node.children.append(cache_node)

                    else:
                        child = self._scan_dir(entry.path, current_depth + 1)
                        node.size += child.size
                        node.file_count += child.file_count
                        dir_cat_sizes[child.category] += child.size
                        node.children.append(child)

            except OSError:
                continue

        # Set dominant category for this directory
        if dir_cat_sizes:
            node.category = max(dir_cat_sizes.items(), key=lambda x: x[1])[0]

        # Sort children descending by size
        node.children.sort(key=lambda x: x.size, reverse=True)
        return node


# ---------------------------------------------------------
# WinDirStat Cushion Treemap Engine
# ---------------------------------------------------------

@dataclass
class TreemapRect:
    x: int
    y: int
    w: int
    h: int
    name: str
    size: int
    category: str
    is_dir: bool


def compute_squarified_treemap(
    x: int, y: int, w: int, h: int, items: List[Dict[str, Any]]
) -> List[TreemapRect]:
    """Recursively partition a rectangle into proportional cushions."""
    if not items or w <= 0 or h <= 0:
        return []
    if len(items) == 1:
        item = items[0]
        return [
            TreemapRect(
                x=x,
                y=y,
                w=w,
                h=h,
                name=item["name"],
                size=item["size"],
                category=item["category"],
                is_dir=item.get("is_dir", True),
            )
        ]

    total = sum(i["size"] for i in items)
    if total <= 0:
        return []

    # Aspect ratio adjustment: terminal characters are approx twice as tall as they are wide.
    split_horizontal = w >= (h * 2.1)

    half = total / 2.0
    acc = 0
    idx = 1
    for i, it in enumerate(items[:-1]):
        acc += it["size"]
        if acc >= half:
            idx = i + 1
            break

    g1 = items[:idx]
    g2 = items[idx:]
    s1 = sum(i["size"] for i in g1)
    ratio = s1 / total

    rects = []
    if split_horizontal:
        w1 = max(1, min(w - 1, int(round(w * ratio))))
        w2 = w - w1
        rects.extend(compute_squarified_treemap(x, y, w1, h, g1))
        rects.extend(compute_squarified_treemap(x + w1, y, w2, h, g2))
    else:
        h1 = max(1, min(h - 1, int(round(h * ratio))))
        h2 = h - h1
        rects.extend(compute_squarified_treemap(x, y, w, h1, g1))
        rects.extend(compute_squarified_treemap(x, y + h1, w, h2, g2))

    return rects


def render_treemap_grid(
    width: int, height: int, items: List[Dict[str, Any]]
) -> List[str]:
    """Render a 2D WinDirStat colored cushion treemap in terminal character cells."""
    if width < 20 or height < 4 or not items:
        return []

    rects = compute_squarified_treemap(0, 0, width, height, items)

    # 2D cell grid: stores (char, color_code, bg_code)
    grid = [[(" ", COLOR_OTHER, "") for _ in range(width)] for _ in range(height)]

    for r in rects:
        cat_info = CATEGORIES.get(r.category, CATEGORIES["other"])
        fg_col = cat_info["color"]
        bg_col = cat_info["bg"]
        pattern = "░" if r.is_dir else "█"

        # Fill rectangle interior
        for cy in range(r.y, min(height, r.y + r.h)):
            for cx in range(r.x, min(width, r.x + r.w)):
                grid[cy][cx] = (pattern, fg_col, bg_col)

        # Draw borders for visual cushion isolation
        if r.w >= 3 and r.h >= 2:
            # Top border
            for cx in range(r.x, min(width, r.x + r.w)):
                grid[r.y][cx] = ("─", COLOR_BORDER, bg_col)
            # Bottom border
            by = min(height - 1, r.y + r.h - 1)
            for cx in range(r.x, min(width, r.x + r.w)):
                grid[by][cx] = ("─", COLOR_BORDER, bg_col)
            # Left & Right borders
            for cy in range(r.y, min(height, r.y + r.h)):
                grid[cy][r.x] = ("│", COLOR_BORDER, bg_col)
                rx = min(width - 1, r.x + r.w - 1)
                grid[cy][rx] = ("│", COLOR_BORDER, bg_col)
            # Corners
            grid[r.y][r.x] = ("┌", COLOR_BORDER, bg_col)
            rx = min(width - 1, r.x + r.w - 1)
            grid[r.y][rx] = ("┐", COLOR_BORDER, bg_col)
            grid[by][r.x] = ("└", COLOR_BORDER, bg_col)
            grid[by][rx] = ("┘", COLOR_BORDER, bg_col)
        elif r.h == 1:
            # 1-row cushion: use smooth solid block
            for cx in range(r.x, min(width, r.x + r.w)):
                grid[r.y][cx] = ("█", fg_col, "")

        # Inscribe label if space allows
        lbl = f"{r.name} {human_size(r.size)}"
        if r.w >= len(lbl) + 4 and r.h >= 3:
            mid_y = r.y + r.h // 2
            start_x = r.x + (r.w - len(lbl)) // 2
            for i, ch in enumerate(lbl):
                if 0 <= start_x + i < width:
                    grid[mid_y][start_x + i] = (ch, f"{BOLD}\033[97m", bg_col)
        elif r.w >= len(r.name) + 2 and r.h >= 2:
            mid_y = r.y + r.h // 2
            start_x = r.x + (r.w - len(r.name)) // 2
            for i, ch in enumerate(r.name):
                if 0 <= start_x + i < width:
                    grid[mid_y][start_x + i] = (ch, f"{BOLD}\033[97m", bg_col)

    lines = []
    for row in grid:
        line_chars = []
        cur_style = ""
        for ch, fg, bg in row:
            style = f"{fg}{bg}"
            if style != cur_style:
                line_chars.append(f"{RESET}{style}")
                cur_style = style
            line_chars.append(ch)
        line_chars.append(RESET)
        lines.append("".join(line_chars))
    return lines


# ---------------------------------------------------------
# Formatting and UI Views
# ---------------------------------------------------------

def get_disk_usage_info(path: str) -> Dict[str, Any]:
    """Retrieve macOS disk usage stats for the filesystem containing path."""
    try:
        stat = os.statvfs(path)
        total = stat.f_blocks * stat.f_frsize
        free = stat.f_bavail * stat.f_frsize
        used = total - free
        percent = (used / total * 100.0) if total > 0 else 0.0
        return {
            "total": total,
            "used": used,
            "free": free,
            "percent": percent,
        }
    except OSError:
        return {"total": 0, "used": 0, "free": 0, "percent": 0.0}


def render_disk_view(
    scanner: DiskScanner,
    term_width: int = 100,
    term_height: int = 40,
) -> str:
    """Compose full WinDirStat-style visual dashboard."""
    output = []
    out = output.append

    disk_info = get_disk_usage_info(scanner.target_path)
    total_sz_str = human_size(scanner.total_size)
    free_sz_str = human_size(disk_info["free"])
    cap_pct = disk_info["percent"]

    # 1. Header Banner
    out(f"{BOLD}{COLOR_CODE}┌── [ /disk ] WinDirStat Terminal Space & Git Analyzer ────────────────────────┐{RESET}")
    path_display = scanner.target_path
    if len(path_display) > term_width - 25:
        path_display = "..." + path_display[-(term_width - 28):]
    out(f"│ {BOLD}Target:{RESET} {path_display}  │  {BOLD}Scanned:{RESET} {total_sz_str} ({scanner.total_files:,} files)")

    # System Disk Bar
    bar_width = min(40, max(20, term_width - 55))
    used_chars = int(round((cap_pct / 100.0) * bar_width))
    free_chars = bar_width - used_chars
    bar_col = "\033[38;5;196m" if cap_pct >= 90 else "\033[38;5;220m" if cap_pct >= 80 else "\033[38;5;42m"
    disk_bar = f"{bar_col}{'█' * used_chars}{DIM}{'░' * free_chars}{RESET}"
    out(f"│ {BOLD}Disk Capacity:{RESET} [{disk_bar}] {BOLD}{cap_pct:.1f}%{RESET} ({free_sz_str} free of {human_size(disk_info['total'])})")
    out(f"{BOLD}{COLOR_CODE}└───────────────────────────────────────────────────────────────────────────────┘{RESET}\n")

    # 2. WinDirStat Visual Treemap Cushion Grid
    treemap_h = min(12, max(6, term_height // 4))
    treemap_w = term_width - 2

    # Prepare top items for treemap (top children of scanned folder)
    treemap_items = []
    if scanner.root_node and scanner.root_node.children:
        for child in scanner.root_node.children:
            if child.size > 0:
                treemap_items.append({
                    "name": child.name,
                    "size": child.size,
                    "category": child.category,
                    "is_dir": child.is_dir,
                })

    out(f"{BOLD}▶ WinDirStat Cushion Treemap (Visual Space Allocation){RESET}")
    if treemap_items:
        lines = render_treemap_grid(treemap_w, treemap_h, treemap_items)
        for line in lines:
            out(f"  {line}")
    else:
        out("  [No data to display in treemap]")
    out("")

    # 3. Category Distribution Bar & Legend
    out(f"{BOLD}▶ File Type Distribution{RESET}")
    dist_bar_w = term_width - 4
    cat_items = sorted(
        [(cat, sz) for cat, sz in scanner.category_sizes.items() if sz > 0],
        key=lambda x: x[1],
        reverse=True,
    )
    total_cat_sz = sum(sz for _, sz in cat_items) or 1

    bar_segments = []
    for cat, sz in cat_items:
        char_count = int(round((sz / total_cat_sz) * dist_bar_w))
        if char_count > 0:
            c_info = CATEGORIES.get(cat, CATEGORIES["other"])
            bar_segments.append(f"{c_info['color']}{'█' * char_count}{RESET}")
    out("  " + "".join(bar_segments))

    # Legend items in compact 2-4 columns
    legend_entries = []
    for cat, sz in cat_items:
        c_info = CATEGORIES.get(cat, CATEGORIES["other"])
        pct = (sz / total_cat_sz) * 100.0
        cnt = scanner.category_counts.get(cat, 0)
        legend_entries.append(
            f"  {c_info['color']}■ {BOLD}{c_info['name']}{RESET}: {human_size(sz)} ({pct:.1f}% · {cnt:,} files)"
        )
    for entry in legend_entries:
        out(entry)
    out("")

    # 4. Top Space Hogs Table
    out(f"{BOLD}▶ Top Space Consumers in Scanned Target{RESET}")
    out(f"  {DIM}{'Rank':<4} {'Type':<8} {'Size':<10} {'Files':<8} {'Percentage Bar':<24} {'Path / Name'}{RESET}")
    out(f"  {DIM}{'─'*4} {'─'*8} {'─'*10} {'─'*8} {'─'*24} {'─'*30}{RESET}")

    if scanner.root_node:
        top_children = scanner.root_node.children[:12]
        for rank, ch in enumerate(top_children, 1):
            pct = (ch.size / scanner.total_size * 100.0) if scanner.total_size > 0 else 0
            c_info = CATEGORIES.get(ch.category, CATEGORIES["other"])
            
            # Progress bar
            bar_len = 16
            filled = int(round((pct / 100.0) * bar_len))
            empty = bar_len - filled
            pct_bar = f"{c_info['color']}{'█' * filled}{DIM}{'░' * empty}{RESET} {pct:4.1f}%"
            
            badge = f"[{c_info['badge']}]"
            name_disp = ch.name + ("/" if ch.is_dir else "")
            if len(name_disp) > 36:
                name_disp = name_disp[:33] + "..."

            out(
                f"  {rank:<4} {c_info['color']}{badge:<8}{RESET} "
                f"{BOLD}{human_size(ch.size):<10}{RESET} {ch.file_count:<8} "
                f"{pct_bar:<35} {name_disp}"
            )
    out("")

    # 5. Specialized Git Radar
    out(f"{BOLD}{COLOR_GIT}▶ Git Repository Radar ({len(scanner.git_repos)} Repositories Audited){RESET}")
    if scanner.git_repos:
        out(f"  {DIM}{'Repository Root':<34} {'Total .git':<11} {'Packs':<14} {'Loose Objects':<16} {'Health / Action'}{RESET}")
        out(f"  {DIM}{'─'*34} {'─'*11} {'─'*14} {'─'*16} {'─'*20}{RESET}")
        for repo in sorted(scanner.git_repos, key=lambda r: r.total_size, reverse=True)[:8]:
            r_name = os.path.basename(repo.root)
            if len(r_name) > 32:
                r_name = r_name[:29] + "..."
            
            pack_str = f"{repo.pack_count} ({human_size(repo.pack_size)})"
            loose_str = f"{repo.loose_count} ({human_size(repo.loose_size)})"
            
            # Status badge
            if "Needs GC" in repo.status_summary:
                status_badge = f"\033[38;5;220m{repo.status_summary}{RESET}"
            elif "Bloated" in repo.status_summary:
                status_badge = f"\033[38;5;196m{BOLD}{repo.status_summary}{RESET}"
            else:
                status_badge = f"\033[38;5;42m{repo.status_summary}{RESET}"

            out(
                f"  {BOLD}{r_name:<34}{RESET} "
                f"{human_size(repo.total_size):<11} "
                f"{pack_str:<14} "
                f"{loose_str:<16} "
                f"{status_badge}"
            )
            if repo.recommendation:
                out(f"    {DIM}└─ Action: {BOLD}{repo.recommendation}{RESET}")
    else:
        out("  No Git repositories detected under this path.")
    out("")

    return "\n".join(output)


# ---------------------------------------------------------
# Interactive TUI Controller (Curses)
# ---------------------------------------------------------

def run_interactive_tui(target_path: str) -> None:
    """Run interactive terminal browser for drill-down navigation."""
    import curses

    def curses_main(stdscr: Any) -> None:
        curses.curs_set(0)
        stdscr.nodelay(False)
        stdscr.keypad(True)

        current_path = os.path.abspath(os.path.expanduser(target_path))

        while True:
            stdscr.clear()
            h, w = stdscr.getmaxyx()

            stdscr.addstr(0, 0, f" Scanning {current_path}... ", curses.A_REVERSE)
            stdscr.refresh()

            scanner = DiskScanner(current_path, max_depth=2)
            scanner.scan()

            content = render_disk_view(scanner, term_width=w, term_height=h)
            lines = content.split("\n")

            stdscr.clear()
            for row_idx, line in enumerate(lines[:h - 1]):
                # Strip ANSI codes for standard curses window if needed, or print raw
                import re
                clean_line = re.sub(r"\033\[[0-9;]*m", "", line)
                try:
                    stdscr.addstr(row_idx, 0, clean_line[:w - 1])
                except curses.error:
                    pass

            stdscr.addstr(h - 1, 0, " [q] Quit  [u] Up Directory  [1-9] Drill down  [r] Rescan ", curses.A_REVERSE)
            stdscr.refresh()

            ch = stdscr.getch()
            if ch in (ord("q"), ord("Q")):
                break
            elif ch in (ord("u"), ord("U")):
                parent = os.path.dirname(current_path)
                if parent and parent != current_path:
                    current_path = parent
            elif ch in (ord("r"), ord("R")):
                continue
            elif ord("1") <= ch <= ord("9"):
                idx = ch - ord("1")
                if scanner.root_node and idx < len(scanner.root_node.children):
                    sel = scanner.root_node.children[idx]
                    if sel.is_dir and os.path.isdir(sel.path):
                        current_path = sel.path

    curses.wrapper(curses_main)


# ---------------------------------------------------------
# Main CLI Entry Point
# ---------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="disk - Visual WinDirStat-style disk space & git analyzer for terminal."
    )
    parser.add_argument(
        "path",
        nargs="?",
        default=".",
        help="Path to inspect (defaults to current directory).",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=3,
        help="Maximum directory traversal depth (default: 3).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON metrics for agent analysis.",
    )
    parser.add_argument(
        "--snapshot",
        action="store_true",
        default=True,
        help="Render complete visual snapshot to current terminal window (default).",
    )
    parser.add_argument(
        "-i",
        "--interactive",
        action="store_true",
        help="Launch interactive drill-down TUI.",
    )

    args = parser.parse_args()
    target_path = os.path.abspath(os.path.expanduser(args.path))

    if args.interactive:
        run_interactive_tui(target_path)
        return

    # Scan directory
    scanner = DiskScanner(target_path, max_depth=args.depth)
    scanner.scan()

    if args.json:
        result = {
            "target_path": scanner.target_path,
            "total_size_bytes": scanner.total_size,
            "total_size_human": human_size(scanner.total_size),
            "total_files": scanner.total_files,
            "categories": {
                cat: {
                    "name": CATEGORIES.get(cat, CATEGORIES["other"])["name"],
                    "bytes": sz,
                    "human": human_size(sz),
                    "files": scanner.category_counts.get(cat, 0),
                }
                for cat, sz in scanner.category_sizes.items()
            },
            "top_consumers": [
                {
                    "name": ch.name,
                    "path": ch.path,
                    "is_dir": ch.is_dir,
                    "bytes": ch.size,
                    "human": human_size(ch.size),
                    "files": ch.file_count,
                    "category": ch.category,
                }
                for ch in (scanner.root_node.children[:15] if scanner.root_node else [])
            ],
            "git_repositories": [
                {
                    "root": repo.root,
                    "total_git_bytes": repo.total_size,
                    "total_git_human": human_size(repo.total_size),
                    "pack_bytes": repo.pack_size,
                    "pack_count": repo.pack_count,
                    "loose_bytes": repo.loose_size,
                    "loose_count": repo.loose_count,
                    "worktrees_count": repo.worktrees_count,
                    "status": repo.status_summary,
                    "recommendation": repo.recommendation,
                }
                for repo in scanner.git_repos
            ],
            "disk_volume": get_disk_usage_info(target_path),
        }
        print(json.dumps(result, indent=2))
        return

    # Snapshot visual view (Default)
    term_cols, term_rows = shutil.get_terminal_size((100, 36))
    view = render_disk_view(scanner, term_width=term_cols, term_height=term_rows)
    print(view)


if __name__ == "__main__":
    main()
