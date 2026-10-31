#!/usr/bin/env python3
# Draws statusline.png for the README: the status line in 4 states and the
# subagent panel. Every row inside a card or the panel is the real output of
# statusline.sh or subagent-statusline.sh, run on a fixture built here with
# its own git repos, config directory and subagent transcript, then drawn in
# the terminal theme's colours. Box lines and the shaded bar are drawn the way
# the terminal draws them, not taken from the font. The rows are printed too,
# so the terminal shows what the picture shows.
import ctypes
import json
import locale
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
FAMILY = "Adwaita Mono"
SIZE = 30
LABEL_SIZE = 26
LINE = 40
MARGIN = 70
BG = (0x16, 0x16, 0x1E)
FG = (0xC0, 0xCA, 0xF5)
LABEL = (0x73, 0x7A, 0xA2)
DIM = 0.55  # share of the foreground that a dim run keeps
PALETTE = {
    31: (0xF7, 0x76, 0x8E),
    32: (0x9E, 0xCE, 0x6A),
    33: (0xE0, 0xAF, 0x68),
    34: (0x7A, 0xA2, 0xF7),
    35: (0xBB, 0x9A, 0xF7),
    36: (0x7D, 0xCF, 0xFF),
    90: (0x6B, 0x73, 0x94),
    97: (0xFF, 0xFF, 0xFF),
}
MARKERS = {  # what the agent panel draws in front of a row, by task status
    "running": ("●", PALETTE[36]),
    "failed": ("✕", PALETTE[31]),
    "killed": ("◌", PALETTE[90]),
    "completed": ("✓", PALETTE[32]),
}
STROKE = 3  # box line thickness
SHADE = (5, 11)  # dots across and down one cell of light shade
BOX = {"─": "h", "│": "v", "┌": "rd", "┐": "ld", "└": "ru", "┘": "lu"}
SGR = re.compile(r"\x1b\[([0-9;]*)m")

locale.setlocale(locale.LC_ALL, "C.UTF-8")
libc = ctypes.CDLL(None)
libc.wcwidth.argtypes = [ctypes.c_wchar]
libc.wcwidth.restype = ctypes.c_int


def font_file(style):
    out = subprocess.run(
        ["fc-match", "-f", "%{family}|%{file}", f"{FAMILY}:{style}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    family, file = out.split("|", 1)
    if FAMILY not in family.split(","):
        sys.exit(f"{FAMILY} is not installed; fc-match offers {family}")
    return file


def git(repo, *args):
    env = {
        "PATH": os.environ["PATH"],
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "LC_ALL": "C.UTF-8",
    }
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            *args,
        ],
        check=True,
        capture_output=True,
        env=env,
    )


def repo(path, branch, files):
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", branch)
    for name in files:
        (path / name).write_text(f"{name}\n")
    git(path, "add", ".")
    git(path, "commit", "-q", "-m", "fixture")
    return path


def dirty(path, staged=(), modified=()):
    for name in staged:
        (path / name).write_text("staged\n")
        git(path, "add", name)
    for name in modified:
        (path / name).write_text("modified\n")


def config_dir(root, tier):
    path = root / f"config-{tier}"
    path.mkdir(exist_ok=True)
    (path / ".claude.json").write_text(
        json.dumps({"oauthAccount": {"organizationRateLimitTier": tier}})
    )
    return path


def run_script(name, fixture, env):
    env = {"PATH": os.environ["PATH"], "LC_ALL": "C.UTF-8", **env}
    out = subprocess.run(
        ["bash", str(HERE / name)],
        input=json.dumps(fixture),
        env=env,
        check=True,
        capture_output=True,
        encoding="utf-8",
    ).stdout
    return out.rstrip("\n").split("\n")


def fixtures(root):
    version = subprocess.run(
        ["claude", "--version"], check=True, capture_output=True, text=True
    ).stdout.split()[0]
    now = int(time.time())
    now_ms = int(time.time() * 1000)
    home = root / "home"
    run = root / "run"
    run.mkdir()
    dotfiles = repo(home / "Documents" / "claude-dotfiles", "main", ["README.md"])
    shiro = repo(
        home / "Documents" / "Shiro-Project",
        "feat/login-form",
        ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts"],
    )
    dirty(shiro, staged=["a.ts", "b.ts"], modified=["c.ts", "d.ts", "e.ts"])
    seledroid = repo(
        home / "Documents" / "seledroid", "release/2.4.0-hotfix", ["build.gradle"]
    )
    dirty(seledroid, modified=["build.gradle"])
    core = seledroid / "app" / "src" / "main" / "java" / "com" / "seledroid" / "core"
    core.mkdir(parents=True)
    notes = home / "Downloads" / "notes"
    notes.mkdir(parents=True)
    transcript = root / "transcripts" / "session.jsonl"
    subagents = root / "transcripts" / "session" / "subagents"
    subagents.mkdir(parents=True)
    transcript.write_text("")
    (subagents / "agent-reviewer1.jsonl").write_text(
        json.dumps({"type": "assistant", "message": {"model": "claude-opus-4-8"}})
        + "\n"
    )

    def card(tier, columns, fixture):
        env = {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(config_dir(root, tier)),
            "XDG_RUNTIME_DIR": str(run),
            "COLUMNS": str(columns),
        }
        return [(line, None) for line in run_script("statusline.sh", fixture, env)]

    fresh = card(
        "default_claude_max_20x",
        100,
        {
            "model": {"id": "claude-fable-5-1", "display_name": "Fable 5.1"},
            "workspace": {"current_dir": str(dotfiles), "project_dir": str(dotfiles)},
            "cwd": str(dotfiles),
            "session_id": "fresh",
            "version": version,
            "context_window": {
                "used_percentage": 3,
                "total_input_tokens": 6100,
                "context_window_size": 200000,
            },
            "cost": {
                "total_cost_usd": 0.02,
                "total_duration_ms": 15000,
                "total_lines_added": 0,
                "total_lines_removed": 0,
            },
            "effort": {"level": "high"},
        },
    )
    pr_open = card(
        "default_claude_max_20x",
        100,
        {
            "model": {"id": "claude-opus-5-5", "display_name": "Opus 5.5"},
            "workspace": {"current_dir": str(shiro), "project_dir": str(shiro)},
            "cwd": str(shiro),
            "session_id": "pr-open",
            "session_name": "login form rewrite",
            "version": version,
            "context_window": {
                "used_percentage": 47.1,
                "total_input_tokens": 94200,
                "context_window_size": 200000,
            },
            "cost": {
                "total_cost_usd": 1.83,
                "total_duration_ms": 2880000,
                "total_lines_added": 312,
                "total_lines_removed": 87,
            },
            "rate_limits": {
                "five_hour": {"used_percentage": 38, "resets_at": now + 8000},
                "seven_day": {
                    "used_percentage": 21,
                    "resets_at": now + 3 * 86400 + 100,
                },
            },
            "effort": {"level": "xhigh"},
            "pr": {"number": 42, "review_state": "pending"},
            "prompt_cache": {
                "warm": True,
                "hit_ratio": 0.92,
                "ttl": "1h",
                "expires_at": now + 2490,
            },
        },
    )
    limits = card(
        "team",
        100,
        {
            "model": {"id": "claude-fable-5-1", "display_name": "Fable 5.1"},
            "workspace": {
                "current_dir": str(core),
                "project_dir": str(seledroid),
                "git_worktree": "hotfix",
            },
            "cwd": str(core),
            "session_id": "limits",
            "version": version,
            "session_name": "crash on resume after permission revoke, reproduce and fix before the 2.4.0 release",
            "context_window": {
                "used_percentage": 88,
                "total_input_tokens": 880400,
                "context_window_size": 1000000,
            },
            "cost": {
                "total_cost_usd": 23.4,
                "total_duration_ms": 11520000,
                "total_lines_added": 2412,
                "total_lines_removed": 1033,
            },
            "rate_limits": {
                "five_hour": {"used_percentage": 91, "resets_at": now + 750},
                "seven_day": {
                    "used_percentage": 64,
                    "resets_at": now + 2 * 86400 + 100,
                },
                "spend_limit": {
                    "used_percentage": 42,
                    "used_usd": 42,
                    "limit_usd": 100,
                },
            },
            "effort": {"level": "max"},
            "fast_mode": True,
            "vim": {"mode": "NORMAL"},
            "agent": {"name": "reviewer"},
            "pr": {"number": 318, "review_state": "changes_requested"},
            "prompt_cache": {"warm": False, "hit_ratio": 0.61, "ttl": "5m"},
        },
    )
    no_git = card(
        "default_claude_pro",
        100,
        {
            "model": {"id": "claude-haiku-5-5", "display_name": "Haiku 5.5"},
            "workspace": {"current_dir": str(notes), "project_dir": str(notes)},
            "cwd": str(notes),
            "session_id": "no-git",
            "version": version,
            "effort": {"level": "low"},
        },
    )
    tasks = [
        {
            "id": "explorer1",
            "name": "explorer",
            "agentType": "Explore",
            "status": "running",
            "label": "Reading src/auth/session.ts",
            "startTime": now_ms - 192500,
            "model": "claude-fable-5-1",
            "effort": "xhigh",
            "contextWindowSize": 200000,
            "tokenCount": 42100,
        },
        {
            "id": "reviewer1",
            "name": "reviewer",
            "agentType": "general-purpose",
            "status": "running",
            "label": "Writing the review of the auth change",
            "startTime": now_ms - 724500,
            "model": "claude-fable-5-1",
            "effort": "high",
            "contextWindowSize": 200000,
            "tokenCount": 116300,
        },
        {
            "id": "builder1",
            "name": "builder",
            "agentType": "Bash",
            "status": "failed",
            "label": "npm test exited 1",
            "startTime": now_ms - 45500,
            "model": "claude-haiku-5-5",
            "effort": "low",
            "contextWindowSize": 200000,
            "tokenCount": 18000,
        },
        {
            "id": "scraper1",
            "name": "scraper",
            "agentType": "general-purpose",
            "status": "killed",
            "label": "Fetching 1,204 pages from the sitemap",
            "startTime": now_ms - 3720500,
            "model": "claude-sonnet-5-5[1m]",
            "effort": "medium",
            "contextWindowSize": 1000000,
            "tokenCount": 812000,
        },
        {
            "id": "docs1",
            "name": "docs",
            "agentType": "claude",
            "status": "completed",
            "label": "Done, 3 files written",
            "startTime": now_ms - 131500,
            "model": "claude-opus-5-5",
            "effort": "high",
            "contextWindowSize": 200000,
            "tokenCount": 9800,
        },
    ]
    rows = run_script(
        "subagent-statusline.sh",
        {"columns": 96, "transcript_path": str(transcript), "tasks": tasks},
        {"XDG_RUNTIME_DIR": str(run)},
    )
    content = {row["id"]: row["content"] for row in map(json.loads, rows)}
    panel = [(content[task["id"]], MARKERS[task["status"]]) for task in tasks]
    return [
        ("FRESH SESSION", fresh),
        ("MID-SESSION, A PR OPEN", pr_open),
        ("NEAR EVERY LIMIT", limits),
        ("NO GIT, NO CONTEXT YET", no_git),
        ("SUBAGENT PANEL", panel),
    ]


def runs(line):
    bold = dim = False
    fg = None
    pos = 0
    for match in SGR.finditer(line):
        if match.start() > pos:
            yield line[pos : match.start()], bold, dim, fg
        codes = [int(code) for code in match.group(1).split(";") if code]
        i = 0
        while i < len(codes):
            code = codes[i]
            if code == 0:
                bold = dim = False
                fg = None
            elif code == 1:
                bold = True
            elif code == 2:
                dim = True
            elif code == 38 and codes[i + 1] == 2:
                fg = tuple(codes[i + 2 : i + 5])
                i += 4
            else:
                fg = PALETTE[code]
            i += 1
        pos = match.end()
    if pos < len(line):
        yield line[pos:], bold, dim, fg


def columns(line):
    return sum(max(libc.wcwidth(ch), 0) for ch in SGR.sub("", line))


def main():
    with tempfile.TemporaryDirectory(prefix="statusline-png-") as tmp:
        sections = fixtures(Path(tmp))
    regular = ImageFont.truetype(font_file("regular"), SIZE)
    bold = ImageFont.truetype(font_file("bold"), SIZE)
    label_font = ImageFont.truetype(font_file("regular"), LABEL_SIZE)
    cell = regular.getlength("M")
    ascent, descent = regular.getmetrics()
    baseline = (LINE - ascent - descent) / 2 + ascent

    widest = max(
        columns(line) + (2 if marker else 0)
        for _, lines in sections
        for line, marker in lines
    )
    height = 77 + sum(48 + LINE * len(lines) + 50 for _, lines in sections) - 50 + 72
    image = Image.new("RGB", (round(2 * MARGIN + widest * cell), height), BG)
    draw = ImageDraw.Draw(image)

    def box(x, y, parts, colour):
        cx, cy, t = x + cell / 2, y + LINE / 2, STROKE / 2
        spans = {
            "h": (x, cy - t, x + cell, cy + t),
            "v": (cx - t, y, cx + t, y + LINE),
            "l": (x, cy - t, cx + t, cy + t),
            "r": (cx - t, cy - t, x + cell, cy + t),
            "u": (cx - t, y, cx + t, cy + t),
            "d": (cx - t, cy - t, cx + t, y + LINE),
        }
        for part in parts:
            draw.rectangle(spans[part], fill=colour)

    def put(col, y, text, font, colour):
        for ch in text:
            width = max(libc.wcwidth(ch), 0)
            x = MARGIN + col * cell
            if ch in BOX:
                box(x, y, BOX[ch], colour)
            elif ch == "█":
                draw.rectangle((x, y, x + cell, y + LINE), fill=colour)
            elif ch == "░":
                for i in range(SHADE[0]):
                    for j in range(SHADE[1]):
                        dx, dy = x + 1 + i * cell / SHADE[0], y + 2 + j * LINE / SHADE[1]
                        draw.rectangle((dx, dy, dx + 1, dy + 1), fill=colour)
            else:
                draw.text((x if width else x - cell, y + baseline), ch, font=font, fill=colour, anchor="ls")
            col += width
        return col

    y = 77
    for label, lines in sections:
        draw.text(
            (MARGIN + 3, y + LINE / 2), label, font=label_font, fill=LABEL, anchor="lm"
        )
        print(label)
        y += 48
        for line, marker in lines:
            col = 0
            if marker:
                col = put(0, y, marker[0], regular, marker[1]) + 1
                print(f"{marker[0]} {line}")
            else:
                print(line)
            for text, is_bold, dim, fg in runs(line):
                colour = fg or FG
                if dim:
                    colour = tuple(
                        round(DIM * c + (1 - DIM) * b) for c, b in zip(colour, BG)
                    )
                col = put(col, y, text, bold if is_bold else regular, colour)
            y += LINE
        y += 50
        print()
    image.save(HERE / "statusline.png")
    print(f"statusline.png {image.width}x{image.height}")


main()
