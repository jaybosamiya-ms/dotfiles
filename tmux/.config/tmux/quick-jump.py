#!/usr/bin/env python3
"""Search visible panes, hint every match, and best-effort move the app cursor."""

from __future__ import annotations

import codecs
import os
import re
import select
import shlex
import subprocess
import sys
import termios
import time
import tty
import unicodedata
from contextlib import contextmanager
from dataclasses import dataclass

DIM = "\033[38;5;244m"
HINT = "\033[1;38;5;232;48;5;215m"
RESET = "\033[0m"

# Keep quick-select's home-row-first ordering, then add enough printable keys
# that unusually common queries can still give each occurrence a destination.
ALPHABET = (
    "asdfjklghqwertyuiopzxcvbnm"
    "ASDFJKLGHQWERTYUIOPZXCVBNM"
    "1234567890"
    "!#$%&()*+,-./:;<=>?@[\\]^_`{|}~\"'"
)

BORDER_GLYPHS = {
    "heavy": "┃ ━ ┏ ┓ ┗ ┛ ┣ ┫ ┻ ┳ ╋",
    "double": "║ ═ ╔ ╗ ╚ ╝ ╠ ╣ ╩ ╦ ╬",
    "simple": "| - + + + + + + + + +",
    "default": "│ ─ ┌ ┐ └ ┘ ├ ┤ ┴ ┬ ┼",
}


@dataclass
class Pane:
    pane_id: str
    left: int
    top: int
    width: int
    height: int
    lines: list[str]


@dataclass
class Match:
    pane_id: str
    pane_row: int
    pane_col: int
    window_row: int
    window_col: int
    text: str
    label: str = ""


def tmux(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["tmux", *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.stdout.rstrip("\n")


def display_width(text: str) -> int:
    width = 0
    for char in text:
        category = unicodedata.category(char)
        if unicodedata.combining(char) or category in {"Mn", "Me", "Cf", "Cc"}:
            continue
        width += 2 if unicodedata.east_asian_width(char) in {"W", "F"} else 1
    return width


def at(row: int, col: int) -> str:
    return f"\033[{row + 1};{col + 1}H"


def capture_lines(pane_id: str, height: int) -> list[str]:
    scroll = tmux("display-message", "-p", "-t", pane_id, "#{scroll_position}")
    args = ["capture-pane", "-p", "-t", pane_id]
    if scroll.isdigit() and int(scroll) > 0:
        offset = int(scroll)
        args.extend(["-S", str(-offset), "-E", str(height - 1 - offset)])
    output = tmux(*args)
    lines = output.split("\n") if output else [""]
    return (lines + [""] * height)[:height]


def capture_window(pane_id: str) -> tuple[str, int, int, list[Pane]]:
    window_id, width, height = tmux(
        "display-message", "-p", "-t", pane_id,
        "#{window_id} #{window_width} #{window_height}",
    ).split()
    panes: list[Pane] = []
    listing = tmux(
        "list-panes", "-t", window_id, "-F",
        "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}",
    )
    for line in listing.splitlines():
        item_id, left, top, pane_width, pane_height = line.split()
        ph = int(pane_height)
        panes.append(
            Pane(
                item_id,
                int(left),
                int(top),
                int(pane_width),
                ph,
                capture_lines(item_id, ph),
            )
        )
    return window_id, int(width), int(height), panes


def border_cells(panes: list[Pane]) -> tuple[set[tuple[int, int]], set[tuple[int, int]], set[tuple[int, int]]]:
    vertical: set[tuple[int, int]] = set()
    horizontal: set[tuple[int, int]] = set()
    cells: set[tuple[int, int]] = set()
    for pane in panes:
        if pane.left > 0:
            for row in range(pane.top, pane.top + pane.height):
                vertical.add((row, pane.left - 1))
                cells.add((row, pane.left - 1))
        if pane.top > 0:
            for col in range(pane.left, pane.left + pane.width):
                horizontal.add((pane.top - 1, col))
                cells.add((pane.top - 1, col))
        if pane.top > 0 and pane.left > 0:
            corner = (pane.top - 1, pane.left - 1)
            vertical.add(corner)
            horizontal.add(corner)
            cells.add(corner)
    return vertical, horizontal, cells


def draw_border(panes: list[Pane]) -> str:
    style = tmux("show-options", "-gv", "pane-border-lines", check=False) or "default"
    glyphs = BORDER_GLYPHS.get(style, BORDER_GLYPHS["default"]).split()
    vertical_glyph, horizontal_glyph = glyphs[:2]
    by_mask = {
        10: glyphs[2], 6: glyphs[3], 9: glyphs[4], 5: glyphs[5],
        11: glyphs[6], 7: glyphs[7], 13: glyphs[8], 14: glyphs[9],
        15: glyphs[10],
    }
    vertical, horizontal, cells = border_cells(panes)
    output: list[str] = []
    for row, col in sorted(cells):
        mask = (
            ((row - 1, col) in vertical)
            + 2 * ((row + 1, col) in vertical)
            + 4 * ((row, col - 1) in horizontal)
            + 8 * ((row, col + 1) in horizontal)
        )
        glyph = by_mask.get(mask, horizontal_glyph if mask in {4, 8, 12} else vertical_glyph)
        output.append(f"{at(row, col)}{DIM}{glyph}{RESET}")
    return "".join(output)


def find_matches(query: str, panes: list[Pane]) -> list[Match]:
    if not query:
        return []
    flags = 0 if any(char.isupper() for char in query) else re.IGNORECASE
    pattern = re.compile(re.escape(query), flags)
    matches: list[Match] = []
    for pane in panes:
        for row, line in enumerate(pane.lines):
            for found in pattern.finditer(line):
                col = display_width(line[:found.start()])
                if col >= pane.width:
                    continue
                matches.append(
                    Match(
                        pane.pane_id,
                        row,
                        col,
                        pane.top + row,
                        pane.left + col,
                        found.group(0),
                    )
                )
    return matches


def labels(count: int) -> list[str]:
    size = len(ALPHABET)
    if count <= size:
        return list(ALPHABET[:count])

    prefixes = next(
        (amount for amount in range(1, size + 1)
         if size - amount + amount * size >= count),
        size,
    )
    singles = size - prefixes
    result = list(ALPHABET[:singles])
    needed = count - singles
    for index in range(needed):
        prefix = ALPHABET[singles + index % prefixes]
        suffix = ALPHABET[index // prefixes]
        result.append(prefix + suffix)
    return result


def assign_labels(matches: list[Match]) -> bool:
    capacity = len(ALPHABET) ** 2
    if len(matches) > capacity:
        return False
    ordered = sorted(matches, key=lambda item: (item.window_row, item.window_col), reverse=True)
    for match, label in zip(ordered, labels(len(ordered))):
        match.label = label
    return True


def base_overlay(panes: list[Pane]) -> str:
    output = ["\033[?7l\033[?25l\033[2J", draw_border(panes)]
    for pane in panes:
        for row, line in enumerate(pane.lines):
            if line:
                output.append(f"{at(pane.top + row, pane.left)}{DIM}{line}{RESET}")
    return "".join(output)


def render_query(panes: list[Pane], height: int, query: str) -> None:
    prompt = f" jump: {query} "
    screen = base_overlay(panes)
    screen += f"{at(height - 1, 0)}{HINT}{prompt}{RESET}"
    sys.stdout.write(screen)
    sys.stdout.flush()


def render_matches(panes: list[Pane], matches: list[Match]) -> None:
    output = [base_overlay(panes)]
    pane_by_id = {pane.pane_id: pane for pane in panes}
    for match in matches:
        pane = pane_by_id[match.pane_id]
        hint_col = min(match.window_col, pane.left + pane.width - len(match.label))
        hint_col = max(pane.left, hint_col)
        output.append(f"{at(match.window_row, hint_col)}{HINT}{match.label}{RESET}")
    sys.stdout.write("".join(output))
    sys.stdout.flush()


class KeyReader:
    def __init__(self, fd: int):
        self.fd = fd
        self.pending: list[str] = []
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def read(self, timeout: float | None) -> str | None:
        if self.pending:
            return self.pending.pop(0)
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return None
        data = os.read(self.fd, 64)
        if not data:
            return "\003"
        self.pending.extend(self.decoder.decode(data))
        return self.pending.pop(0) if self.pending else self.read(timeout)


@contextmanager
def raw_terminal():
    fd = sys.stdin.fileno()
    previous = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        yield KeyReader(fd)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, previous)
        sys.stdout.write(f"{RESET}\033[?7h\033[?25h")
        sys.stdout.flush()


def collect_query(reader: KeyReader, panes: list[Pane], height: int) -> str | None:
    query = ""
    deadline: float | None = None
    while True:
        render_query(panes, height, query)
        timeout = None if deadline is None else max(0.0, deadline - time.monotonic())
        key = reader.read(timeout)
        if key is None:
            return query
        if key in {"\033", "\003"}:
            return None
        if key in {"\r", "\n"}:
            return query
        if key in {"\x08", "\x7f"}:
            query = query[:-1]
            deadline = time.monotonic() + 0.3 if query else None
        elif key.isprintable():
            query += key
            deadline = time.monotonic() + 0.3


def choose_match(reader: KeyReader, matches: list[Match]) -> Match | None:
    by_label = {match.label: match for match in matches}
    prefixes = {label[0] for label in by_label if len(label) == 2}
    key = reader.read(None)
    if key is None or key in {"\033", "\003", "\r", "\n"}:
        return None
    if key in by_label:
        return by_label[key]
    if key not in prefixes:
        return None
    second = reader.read(None)
    if second is None or second in {"\033", "\003", "\r", "\n"}:
        return None
    return by_label.get(key + second)


def cursor_position(pane_id: str) -> tuple[int, int] | None:
    output = tmux(
        "display-message", "-p", "-t", pane_id, "#{cursor_x} #{cursor_y}",
        check=False,
    )
    try:
        x, y = output.split()
        return int(x), int(y)
    except (ValueError, TypeError):
        return None


def move_real_cursor(match: Match, panes: list[Pane]) -> None:
    pane = next((item for item in panes if item.pane_id == match.pane_id), None)
    if pane is None:
        return
    target_x = min(max(match.pane_col, 0), pane.width - 1)
    target_y = min(max(match.pane_row, 0), pane.height - 1)

    tmux("select-pane", "-t", match.pane_id, check=False)
    if tmux("display-message", "-p", "-t", match.pane_id, "#{pane_in_mode}", check=False) != "0":
        tmux("send-keys", "-t", match.pane_id, "-X", "cancel", check=False)
    # Let focus changes and copy-mode cancellation settle before establishing
    # the rows that arrow-key movement is allowed to preserve. Ignore unrelated
    # animation elsewhere in the pane, but include one row of padding around
    # the path from the original cursor row to the destination row.
    time.sleep(0.04)
    initial = cursor_position(match.pane_id)
    if initial is None:
        return
    first_row = max(0, min(initial[1], target_y) - 1)
    last_row = min(pane.height, max(initial[1], target_y) + 2)

    def movement_rows() -> list[str]:
        return capture_lines(match.pane_id, pane.height)[first_row:last_row]

    expected_lines = movement_rows()

    for _ in range(6):
        current = cursor_position(match.pane_id)
        if current is None:
            return
        current_x, current_y = current
        before = abs(target_x - current_x) + abs(target_y - current_y)
        if before == 0:
            return

        # Vertical movement is more reliable in prompts such as readline when
        # it starts at column zero. Re-anchor there before changing rows, then
        # calculate the final horizontal move from the observed position.
        if target_y != current_y and current_x > 0:
            tmux(
                "send-keys", "-N", str(current_x),
                "-t", match.pane_id, "Left", check=False,
            )
            time.sleep(0.02)
            if movement_rows() != expected_lines:
                return
            anchored = cursor_position(match.pane_id)
            if anchored is None:
                return
            current_x, current_y = anchored

        if target_y != current_y:
            key = "Down" if target_y > current_y else "Up"
            tmux(
                "send-keys", "-N", str(abs(target_y - current_y)),
                "-t", match.pane_id, key, check=False,
            )
            time.sleep(0.02)
            if movement_rows() != expected_lines:
                return
            moved = cursor_position(match.pane_id)
            if moved is None:
                return
            current_x, current_y = moved

        if target_x != current_x:
            key = "Right" if target_x > current_x else "Left"
            tmux(
                "send-keys", "-N", str(abs(target_x - current_x)),
                "-t", match.pane_id, key, check=False,
            )

        time.sleep(0.04)
        if movement_rows() != expected_lines:
            return
        observed = cursor_position(match.pane_id)
        if observed is None:
            return
        after = abs(target_x - observed[0]) + abs(target_y - observed[1])
        if after == 0 or after >= before:
            return


def launch(pane_id: str) -> int:
    details = tmux(
        "display-message", "-p", "-t", pane_id,
        "#{window_width} #{window_height} #{status} #{status-position}",
    ).split()
    width, height, status, position = details
    if status == "off":
        status_lines = 0
    elif status.isdigit():
        status_lines = int(status)
    else:
        status_lines = 1
    if position != "top":
        status_lines = 0
    bottom = status_lines + int(height)
    command = shlex.join([os.path.realpath(__file__), "--overlay", pane_id])
    return subprocess.run(
        [
            "tmux", "display-popup", "-B", "-E", "-t", pane_id,
            "-x", "0", "-y", str(bottom), "-w", width, "-h", height,
            command,
        ],
        check=False,
    ).returncode


def overlay(pane_id: str) -> int:
    _, _, height, panes = capture_window(pane_id)
    with raw_terminal() as reader:
        query = collect_query(reader, panes, height)
        if query is None:
            return 0
        matches = find_matches(query, panes)
        if not matches:
            tmux("display-message", "jump-select: no matches", check=False)
            return 0
        if not assign_labels(matches):
            tmux("display-message", "jump-select: too many matches for two-key hints", check=False)
            return 0
        render_matches(panes, matches)
        chosen = choose_match(reader, matches)
        if chosen is not None:
            move_real_cursor(chosen, panes)
    return 0


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "--overlay":
        return overlay(sys.argv[2])
    pane_id = sys.argv[1] if len(sys.argv) >= 2 else os.environ.get("TMUX_PANE")
    if not pane_id:
        pane_id = tmux("display-message", "-p", "#{pane_id}")
    return launch(pane_id)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError, termios.error, ValueError) as error:
        tmux("display-message", f"jump-select: {error}", check=False)
        raise SystemExit(1)
