#!/usr/bin/env python3
"""A small, dependency-free macOS system dashboard.

The dashboard intentionally uses macOS' built-in command line tools instead of
third-party packages. It is designed to be useful on Apple Silicon without
requiring sudo or private APIs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import math
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import time
import tty
from collections import deque
from dataclasses import dataclass, field
from typing import Deque, Iterable, Optional, Sequence


APP_NAME = "macdash"
DEFAULT_INTERVAL = 1.5
MAX_HISTORY = 96


@dataclass
class CommandResult:
    stdout: str = ""
    returncode: int = 1


def run_command(args: Sequence[str], timeout: float = 2.0) -> CommandResult:
    """Run one native macOS command and turn failures into an empty result."""

    try:
        result = subprocess.run(
            list(args),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return CommandResult(result.stdout, result.returncode)
    except (OSError, subprocess.SubprocessError):
        return CommandResult()


def parse_float(pattern: str, text: str, flags: int = re.IGNORECASE) -> Optional[float]:
    match = re.search(pattern, text, flags)
    if not match:
        return None
    try:
        return float(match.group(1))
    except (TypeError, ValueError):
        return None


def parse_int(pattern: str, text: str, flags: int = re.IGNORECASE) -> Optional[int]:
    value = parse_float(pattern, text, flags)
    return int(value) if value is not None else None


def parse_top_summary(text: str) -> tuple[Optional[float], Optional[float], tuple[float, ...]]:
    """Read CPU, physical memory, and load averages from top's summary."""

    cpu = None
    match = re.search(r"CPU usage:\s*([\d.]+)%\s*user,\s*([\d.]+)%\s*sys", text, re.I)
    if match:
        try:
            cpu = min(100.0, max(0.0, float(match.group(1)) + float(match.group(2))))
        except ValueError:
            pass

    memory_used_bytes = None
    match = re.search(r"PhysMem:\s*([\d.]+)\s*([KMGTP])\s+used", text, re.I)
    if match:
        memory_used_bytes = bytes_from_unit(float(match.group(1)), match.group(2))

    load_values: tuple[float, ...] = ()
    match = re.search(r"Load Avg:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)", text, re.I)
    if match:
        load_values = tuple(float(value) for value in match.groups())
    if not load_values:
        match = re.search(r"load averages?:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)", text, re.I)
        if match:
            load_values = tuple(float(value) for value in match.groups())

    return cpu, memory_used_bytes, load_values


def bytes_from_unit(value: float, unit: str) -> float:
    units = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}
    return value * units.get(unit.upper(), 1)


def parse_swap_usage(text: str) -> tuple[Optional[float], Optional[float]]:
    used = parse_float(r"used\s*=\s*([\d.]+)\s*([KMGTP])", text)
    total = parse_float(r"total\s*=\s*([\d.]+)\s*([KMGTP])", text)
    # The unit is captured separately to keep this parser easy to test.
    unit_match = re.search(r"total\s*=\s*[\d.]+\s*([KMGTP])", text, re.I)
    unit = unit_match.group(1) if unit_match else "M"
    if used is None or total is None:
        return None, None
    return bytes_from_unit(used, unit), bytes_from_unit(total, unit)


def parse_gpu_usage(text: str) -> Optional[float]:
    """Parse the public-ish utilization field emitted by IOAccelerator."""

    values = re.findall(r"(?:Device|Renderer|Tiler) Utilization\s*%\"?\s*=\s*([\d.]+)", text, re.I)
    if not values:
        return None
    try:
        return min(100.0, max(0.0, sum(float(value) for value in values) / len(values)))
    except ValueError:
        return None


def parse_memory_from_vm_stat(text: str, total_bytes: Optional[float]) -> Optional[float]:
    """Fallback memory estimate when top's PhysMem line is unavailable."""

    if not total_bytes:
        return None
    page_size = parse_int(r"page size of\s+(\d+)\s+bytes", text)
    page_size = page_size or 4096
    pages: dict[str, int] = {}
    for name, value in re.findall(r"^Pages\s+(.+?):\s+(\d+)\.", text, re.M):
        pages[name.strip().lower()] = int(value)
    free = pages.get("free", 0) + pages.get("speculative", 0) + pages.get("purgeable", 0)
    return max(0.0, total_bytes - free * page_size)


def parse_network_counters(text: str) -> tuple[int, int]:
    """Return total RX/TX bytes from netstat's link rows.

    Link rows have an optional address column, so the parser first finds the
    <Link#N> marker and then accounts for either row shape.
    """

    rx = 0
    tx = 0
    for line in text.splitlines():
        if "<Link#" not in line:
            continue
        tail = line.split(">", 1)[-1].split()
        if len(tail) >= 8:
            # Some macOS versions include a link address; others leave it blank.
            tail = tail[1:] if not tail[0].isdigit() else tail
        if len(tail) < 6:
            continue
        try:
            rx += int(tail[2])
            tx += int(tail[5])
        except (TypeError, ValueError):
            continue
    return rx, tx


def parse_disk_usage(text: str) -> Optional[float]:
    match = re.search(r"\s(\d+)%\s+\d+\s+\d+\s+\d+%\s+/\s*$", text, re.M)
    if not match:
        match = re.search(r"\s(\d+)%\s+\d+\s+\d+\s+\d+%\s+/.+$", text, re.M)
    return float(match.group(1)) if match else None


def parse_battery(text: str) -> tuple[Optional[float], str]:
    level = parse_float(r"(\d+)%", text)
    if level is None:
        return None, "n/a"
    lower = text.lower()
    if "charging" in lower:
        state = "charging"
    elif "discharging" in lower:
        state = "battery"
    elif "ac power" in lower or "charged" in lower:
        state = "plugged"
    else:
        state = "battery"
    return level, state


def parse_boot_time(text: str) -> Optional[float]:
    seconds = parse_float(r"sec\s*=\s*(\d+)", text)
    return seconds


def format_bytes(value: Optional[float], per_second: bool = False) -> str:
    if value is None:
        return "n/a"
    suffixes = ("B", "K", "M", "G", "T")
    scaled = max(0.0, float(value))
    suffix = suffixes[0]
    for suffix in suffixes:
        if scaled < 1024 or suffix == suffixes[-1]:
            break
        scaled /= 1024
    if scaled >= 100:
        formatted = f"{scaled:.0f}"
    elif scaled >= 10:
        formatted = f"{scaled:.1f}"
    else:
        formatted = f"{scaled:.2f}"
    return f"{formatted}{suffix}{'/s' if per_second else ''}"


def format_duration(seconds: Optional[float]) -> str:
    if seconds is None or seconds < 0:
        return "n/a"
    seconds = int(seconds)
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes, _ = divmod(seconds, 60)
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes:02d}m"
    return f"{minutes}m"


@dataclass
class Sample:
    timestamp: float = field(default_factory=time.time)
    cpu: Optional[float] = None
    gpu: Optional[float] = None
    memory_used: Optional[float] = None
    memory_total: Optional[float] = None
    swap_used: Optional[float] = None
    swap_total: Optional[float] = None
    rx_rate: Optional[float] = None
    tx_rate: Optional[float] = None
    load: tuple[float, ...] = ()
    uptime: Optional[float] = None
    disk: Optional[float] = None
    battery: Optional[float] = None
    battery_state: str = "n/a"
    thermal: str = "n/a"
    errors: tuple[str, ...] = ()


class Collector:
    """Collect and derive metrics while retaining network counter state."""

    def __init__(self) -> None:
        self.previous_network: Optional[tuple[float, int, int]] = None

    def collect(self) -> Sample:
        errors: list[str] = []
        now = time.time()
        top = run_command(("/usr/bin/top", "-l", "1", "-n", "0", "-stats", "pid"), timeout=3.0).stdout
        cpu, memory_used, load = parse_top_summary(top)
        if cpu is None:
            errors.append("CPU")

        total_memory = self._sysctl_bytes("hw.memsize")
        if memory_used is None:
            vm_stat = run_command(("/usr/bin/vm_stat",), timeout=1.0).stdout
            memory_used = parse_memory_from_vm_stat(vm_stat, total_memory)
        if memory_used is None:
            errors.append("RAM")

        swap_used, swap_total = parse_swap_usage(
            run_command(("/usr/sbin/sysctl", "vm.swapusage"), timeout=1.0).stdout
        )
        if swap_used is None:
            errors.append("swap")

        gpu = parse_gpu_usage(
            run_command(("/usr/sbin/ioreg", "-r", "-c", "IOAccelerator", "-w", "0"), timeout=2.0).stdout
        )
        if gpu is None:
            errors.append("GPU")

        rx_rate, tx_rate = self._network_rates(now)
        if rx_rate is None or tx_rate is None:
            errors.append("network")

        boot = parse_boot_time(run_command(("/usr/sbin/sysctl", "-n", "kern.boottime"), timeout=1.0).stdout)
        uptime = max(0.0, now - boot) if boot is not None else None
        disk = parse_disk_usage(run_command(("/bin/df", "-k", "/"), timeout=1.0).stdout)
        battery, battery_state = parse_battery(
            run_command(("/usr/bin/pmset", "-g", "batt"), timeout=1.0).stdout
        )
        thermal = self._thermal_state()
        if not load:
            errors.append("load")

        return Sample(
            timestamp=now,
            cpu=cpu,
            gpu=gpu,
            memory_used=memory_used,
            memory_total=total_memory,
            swap_used=swap_used,
            swap_total=swap_total,
            rx_rate=rx_rate,
            tx_rate=tx_rate,
            load=load,
            uptime=uptime,
            disk=disk,
            battery=battery,
            battery_state=battery_state,
            thermal=thermal,
            errors=tuple(errors),
        )

    def _sysctl_bytes(self, key: str) -> Optional[float]:
        result = run_command(("/usr/sbin/sysctl", "-n", key), timeout=1.0).stdout.strip()
        try:
            return float(result)
        except ValueError:
            return None

    def _network_rates(self, now: float) -> tuple[Optional[float], Optional[float]]:
        rx, tx = parse_network_counters(
            run_command(("/usr/sbin/netstat", "-ibn"), timeout=1.0).stdout
        )
        if self.previous_network is None:
            self.previous_network = (now, rx, tx)
            return 0.0, 0.0
        previous_time, previous_rx, previous_tx = self.previous_network
        self.previous_network = (now, rx, tx)
        elapsed = now - previous_time
        if elapsed <= 0:
            return 0.0, 0.0
        return max(0.0, (rx - previous_rx) / elapsed), max(0.0, (tx - previous_tx) / elapsed)

    @staticmethod
    def _thermal_state() -> str:
        text = run_command(("/usr/bin/pmset", "-g", "therm"), timeout=1.0).stdout.lower()
        if not text:
            return "n/a"
        if "no thermal warning" in text and "no performance warning" in text:
            return "nominal"
        if "warning" in text or "thrott" in text:
            return "watch"
        return "nominal"


class Theme:
    RESET = "\033[0m"
    DIM = "\033[2m"
    BOLD = "\033[1m"
    CYAN = "\033[38;5;81m"
    GREEN = "\033[38;5;120m"
    YELLOW = "\033[38;5;221m"
    MAGENTA = "\033[38;5;213m"
    BLUE = "\033[38;5;117m"
    RED = "\033[38;5;203m"
    MUTED = "\033[38;5;245m"
    WHITE = "\033[38;5;255m"

    def __init__(self, enabled: bool = True) -> None:
        self.enabled = enabled

    def paint(self, text: str, color: str) -> str:
        return f"{color}{text}{self.RESET}" if self.enabled else text

    def bold(self, text: str) -> str:
        return f"{self.BOLD}{text}{self.RESET}" if self.enabled else text

    def dim(self, text: str) -> str:
        return f"{self.DIM}{text}{self.RESET}" if self.enabled else text


def visible_length(text: str) -> int:
    return len(re.sub(r"\033\[[0-9;]*m", "", text))


def pad_visible(text: str, width: int, align: str = "left") -> str:
    text = text[:width] if visible_length(text) > width else text
    padding = max(0, width - visible_length(text))
    if align == "right":
        return " " * padding + text
    return text + " " * padding


def sparkline(values: Iterable[Optional[float]], width: int, low: float, high: float, theme: Theme, color: str) -> str:
    bars = "▁▂▃▄▅▆▇█"
    values = list(values)[-max(1, width):]
    values = [None] * max(0, width - len(values)) + values
    output = []
    span = max(0.0001, high - low)
    for value in values:
        if value is None:
            output.append("·")
            continue
        level = int(round((max(low, min(high, value)) - low) / span * (len(bars) - 1)))
        output.append(bars[level])
    return theme.paint("".join(output), color)


def metric_row(
    label: str,
    value: str,
    values: Deque[Optional[float]],
    width: int,
    theme: Theme,
    color: str,
    low: float = 0,
    high: float = 100,
) -> str:
    graph_width = max(8, width - 15)
    prefix = f"{theme.paint(label, color)} {theme.bold(pad_visible(value, 8, 'right'))} "
    graph = sparkline(values, graph_width, low, high, theme, color)
    return pad_visible(prefix + graph, width)


def horizontal_rule(width: int, left: str = "├", right: str = "┤") -> str:
    return left + "─" * max(0, width - 2) + right


def panel(title: str, rows: list[str], width: int, theme: Theme) -> list[str]:
    title_text = f"─ {title} "
    top = "╭" + pad_visible(title_text, width - 2) + "╮"
    bottom = "╰" + "─" * (width - 2) + "╯"
    body = ["│" + pad_visible(row, width - 2) + "│" for row in rows]
    return [top, *body, bottom]


class Dashboard:
    def __init__(self, theme: Theme, max_history: int = MAX_HISTORY) -> None:
        self.theme = theme
        self.collector = Collector()
        self.history: dict[str, Deque[Optional[float]]] = {
            name: deque(maxlen=max_history)
            for name in ("cpu", "gpu", "memory", "swap", "rx", "tx")
        }
        self.last_sample: Optional[Sample] = None

    def add(self, sample: Sample) -> None:
        self.last_sample = sample
        values = {
            "cpu": sample.cpu,
            "gpu": sample.gpu,
            "memory": self._percent(sample.memory_used, sample.memory_total),
            "swap": self._percent(sample.swap_used, sample.swap_total),
            "rx": sample.rx_rate,
            "tx": sample.tx_rate,
        }
        for name, value in values.items():
            self.history[name].append(value)

    @staticmethod
    def _percent(used: Optional[float], total: Optional[float]) -> Optional[float]:
        if used is None or not total:
            return None
        return max(0.0, min(100.0, used / total * 100))

    def reset_history(self) -> None:
        for values in self.history.values():
            values.clear()

    def render(self, interval: float, width: Optional[int] = None, height: Optional[int] = None) -> str:
        sample = self.last_sample or Sample()
        terminal = shutil.get_terminal_size((100, 30))
        width = max(54, min(width or terminal.columns, 140))
        height = height or terminal.lines
        inner = width - 2
        machine = self._machine_name()
        cores = self._cores()
        now = dt.datetime.fromtimestamp(sample.timestamp).strftime("%H:%M:%S")
        subtitle = f"{now}  ·  {machine}  ·  {cores}c  ·  refresh {interval:.1f}s"

        lines = [
            "╭" + "─" * inner + "╮",
            "│" + pad_visible(f"  {theme_mark(self.theme, APP_NAME, Theme.CYAN)}  {self.theme.dim('system vital signs')}", inner) + "│",
            "│" + pad_visible(f"  {self.theme.dim(subtitle)}", inner) + "│",
            "├" + "─" * inner + "┤",
        ]

        left_width = (inner - 3) // 2
        right_width = inner - 3 - left_width
        cards = [
            metric_row(
                "CPU", f"{sample.cpu:.0f}%" if sample.cpu is not None else "n/a",
                self.history["cpu"], left_width, self.theme, Theme.CYAN,
            ),
            metric_row(
                "GPU", f"{sample.gpu:.0f}%" if sample.gpu is not None else "n/a",
                self.history["gpu"], right_width, self.theme, Theme.MAGENTA,
            ),
            metric_row(
                "RAM", f"{format_bytes(sample.memory_used)}" if sample.memory_used is not None else "n/a",
                self.history["memory"], left_width, self.theme, Theme.GREEN,
            ),
            metric_row(
                "SWAP", f"{format_bytes(sample.swap_used)}" if sample.swap_used is not None else "n/a",
                self.history["swap"], right_width, self.theme, Theme.YELLOW,
            ),
            metric_row(
                "RX", format_bytes(sample.rx_rate, True), self.history["rx"], left_width,
                self.theme, Theme.BLUE, 0, self._network_scale(sample.rx_rate, self.history["rx"]),
            ),
            metric_row(
                "TX", format_bytes(sample.tx_rate, True), self.history["tx"], right_width,
                self.theme, Theme.BLUE, 0, self._network_scale(sample.tx_rate, self.history["tx"]),
            ),
        ]
        for index in range(0, len(cards), 2):
            lines.append("│ " + pad_visible(cards[index], left_width) + " │ " + pad_visible(cards[index + 1], right_width) + " │")

        lines.append("├" + "─" * inner + "┤")
        load = "  ".join(f"{value:.2f}" for value in sample.load) if sample.load else "n/a"
        disk = f"{sample.disk:.0f}%" if sample.disk is not None else "n/a"
        battery = f"{sample.battery:.0f}%" if sample.battery is not None else "n/a"
        battery_suffix = " ⚡" if sample.battery_state == "charging" else ""
        status = [
            f"{self.theme.paint('LOAD', Theme.CYAN)} {load}",
            f"{self.theme.paint('UP', Theme.GREEN)} {format_duration(sample.uptime)}",
            f"{self.theme.paint('DISK', Theme.YELLOW)} {disk}",
            f"{self.theme.paint('BAT', Theme.MAGENTA)} {battery}{battery_suffix}",
            f"{self.theme.paint('THERM', Theme.RED if sample.thermal == 'watch' else Theme.GREEN)} {sample.thermal}",
        ]
        if width >= 100:
            status_lines = ["  ·  ".join(status)]
        else:
            # Keep the optional metrics visible on an ordinary 80-column shell.
            status_lines = ["  ·  ".join(status[:2]), "  ·  ".join(status[2:])]
        for status_line in status_lines:
            lines.append("│ " + pad_visible(status_line, inner - 2) + " │")
        lines.append("├" + "─" * inner + "┤")
        if sample.errors:
            notice = self.theme.paint("n/a", Theme.YELLOW) + " " + self.theme.dim("unavailable: " + ", ".join(sample.errors))
        else:
            notice = self.theme.paint("● LIVE", Theme.GREEN) + self.theme.dim("  native macOS sources")
        footer = notice + self.theme.dim("  ·  q quit  r reset  +/- interval")
        lines.append("│ " + pad_visible(footer, inner - 2) + " │")
        lines.append("╰" + "─" * inner + "╯")

        if height < len(lines):
            lines = lines[: max(1, height - 1)] + [self.theme.dim("… terminal is too short …")]
        return "\n".join(lines)

    @staticmethod
    def _network_scale(current: Optional[float], values: Deque[Optional[float]]) -> float:
        observed = [value for value in values if value is not None]
        peak = max(observed + ([current] if current is not None else [0.0]))
        return max(1024.0, peak * 1.2)

    @staticmethod
    def _machine_name() -> str:
        result = run_command(("/usr/sbin/sysctl", "-n", "hw.model"), timeout=1.0).stdout.strip()
        return result or "Mac"

    @staticmethod
    def _cores() -> str:
        result = run_command(("/usr/sbin/sysctl", "-n", "hw.ncpu"), timeout=1.0).stdout.strip()
        return result or "?"


def theme_mark(theme: Theme, text: str, color: str) -> str:
    return theme.paint(text, color)


def get_key(timeout: float) -> Optional[str]:
    readable, _, _ = select.select([sys.stdin], [], [], max(0.0, timeout))
    if not readable:
        return None
    try:
        return sys.stdin.read(1)
    except (OSError, IOError):
        return None


def run_once(args: argparse.Namespace) -> int:
    dashboard = Dashboard(Theme(enabled=not args.no_color and sys.stdout.isatty()))
    dashboard.add(dashboard.collector.collect())
    print(dashboard.render(args.interval))
    return 0


def run_interactive(args: argparse.Namespace) -> int:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("macdash needs an interactive terminal; try `./macdash --once` for a snapshot.", file=sys.stderr)
        return 2

    dashboard = Dashboard(Theme(enabled=not args.no_color))
    interval = args.interval
    old_settings = termios.tcgetattr(sys.stdin)
    sys.stdout.write("\033[?1049h\033[?25l\033[2J\033[H")
    sys.stdout.flush()
    try:
        tty.setcbreak(sys.stdin.fileno())
        while True:
            started = time.monotonic()
            dashboard.add(dashboard.collector.collect())
            sys.stdout.write("\033[H\033[2J" + dashboard.render(interval))
            sys.stdout.flush()
            remaining = interval
            while remaining > 0:
                key = get_key(min(0.1, remaining))
                if key:
                    if key.lower() == "q" or key == "\x03":
                        return 0
                    if key.lower() == "r":
                        dashboard.reset_history()
                    elif key in ("+", "="):
                        interval = max(0.5, round(interval - 0.25, 2))
                    elif key in ("-", "_"):
                        interval = min(10.0, round(interval + 0.25, 2))
                remaining = interval - (time.monotonic() - started)
    except KeyboardInterrupt:
        return 0
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        sys.stdout.write("\033[?25h\033[?1049l")
        sys.stdout.flush()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=APP_NAME, description="Tiny dependency-free macOS vital-signs dashboard.")
    parser.add_argument("--once", action="store_true", help="print one snapshot and exit")
    parser.add_argument("--no-color", action="store_true", help="disable ANSI colors")
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL, help="refresh interval in seconds (0.5–10)")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not 0.5 <= args.interval <= 10:
        parser.error("--interval must be between 0.5 and 10 seconds")
    return run_once(args) if args.once else run_interactive(args)


if __name__ == "__main__":
    raise SystemExit(main())
