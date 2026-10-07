#!/usr/bin/env python3
"""Level Studio: a local web editor for the built-in levels (development tool).

The in-game editor is built for players; this one is for designing the level
set itself. It shows every level side by side with its solver metrics, edits
maps on a grid or as XSB text, play-tests in the browser and opens the level in
Godot with one click.

Usage::

    python3 tools/level_studio.py                 # serves http://127.0.0.1:8765
    python3 tools/level_studio.py --port 9000 --no-browser

The server only listens on localhost and reads/writes ``levels/*.json``
directly. Files are written with ``solver.dump_level`` (the same canonical
layout as ``tools/solver.py --write``), so saving an unchanged level produces
no diff. Solving, validation and trap analysis reuse ``tools/solver.py`` and
run in a child process with a timeout, so a huge or unsolvable draft can never
hang the server.

API (JSON over HTTP)::

    GET  /api/levels                 all level files in load order
    POST /api/analyze  {map, traps}  validate + solve (+ trap profile)
    POST /api/save     {id, data}    write levels/<id>.json
    POST /api/create   {from?}       new level (or a copy of <from>)
    POST /api/delete   {id}
    POST /api/swap     {a, b}        swap the order of two levels
    POST /api/play     {id}          launch Godot straight into the level
"""

from __future__ import annotations

import argparse
import copy
import dataclasses
import json
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
LEVELS = ROOT / "levels"
PAGE = TOOLS / "level_studio.html"
FONT = ROOT / "fonts" / "NotoSansSC-500.ttf"

sys.path.insert(0, str(TOOLS))
import solver as sk  # noqa: E402  (tools/solver.py)

THEMES = ("dawn", "garden", "dusk", "lavender", "night")   # LevelData.THEMES
ID_RE = re.compile(r"^[0-9A-Za-z_-]{1,32}$")
SOLVE_TIMEOUT = 15.0        # seconds for validate + solve
TRAP_TIMEOUT = 90.0         # seconds for the trap profile
TRAP_MAX_STATES = 200_000   # per solvability check in the trap profile
GODOT_CANDIDATES = (
    os.environ.get("GODOT", ""),
    "/Applications/Godot 4.6.3.app/Contents/MacOS/Godot",
    "/Applications/Godot.app/Contents/MacOS/Godot",
    shutil.which("godot") or "",
)

# Solver messages are English; the studio UI is Chinese.
MESSAGES = (
    (r"^map is empty$", "地图是空的"),
    (r"^expected exactly one player, found 0$", "需要放置一名玩家"),
    (r"^expected exactly one player, found (\d+)$", r"只能有一名玩家（现在有 \1 个）"),
    (r"^play area is not enclosed by walls \(leaks at x=(\d+), y=(\d+)\)$", r"可走区域没有被墙围住（在 (\1,\2) 附近漏出）"),
    (r"^cells not reachable from the player: (.*)$", r"有格子玩家走不到：\1"),
    (r"^unknown map character (.*) at x=(\d+), y=(\d+)$", r"未知地图字符 \1，位置 (\2,\3)"),
    (r"^level has no boxes$", "至少需要一个箱子"),
    (r"^(\d+) boxes but (\d+) targets$", r"箱子数（\1）与目标数（\2）不一致"),
    (r"^level is already solved$", "所有箱子一开始就在目标上"),
    (r"^box starts on a dead square at x=(\d+), y=(\d+)$", r"箱子一开始就在死格上 (\1,\2)，永远推不到目标"),
    (r"^grid (\d+)x(\d+) exceeds (\d+)x(\d+)$", r"尺寸 \1×\2 超出建议上限 \3×\4"),
    (r"^(\d+) floor cells exceed (\d+)$", r"地板 \1 格，超出建议上限 \2 格"),
    (r"^(\d+) interior floor cell\(s\) written as spaces; use '-'$", r"有 \1 个内部地板写成了空格"),
)


def zh(message: str) -> str:
    for pattern, repl in MESSAGES:
        if re.match(pattern, message):
            return re.sub(pattern, repl, message)
    return message


# --------------------------------------------------------------------------
# Analysis (runs in a child process, see run_worker)
# --------------------------------------------------------------------------

def analyze(rows: list[str], with_traps: bool) -> dict:
    """Validate and solve a map. Returns plain JSON-able data."""
    out: dict = {"errors": [], "warnings": []}
    try:
        level = sk.parse_map(rows)
    except sk.LevelError as exc:
        out["errors"].append(zh(str(exc)))
        return out
    solver = sk.Solver(level)
    errors, warnings = sk.validate(level, solver)
    out["errors"] += [zh(e) for e in errors]
    out["warnings"] += [zh(w) for w in warnings]
    out["layout"] = {
        "width": level.width,
        "height": level.height,
        "floor": level.floor_count,
        "boxes": len(level.boxes),
        "dead": [level.xy(c) for c in solver.dead_cells()],
    }
    if errors:
        return out
    try:
        solution = solver.solve(sk.DEFAULT_MAX_STATES)
    except sk.SearchLimitError:
        out["errors"].append("搜索超限：状态太多，无法确认是否可解")
        return out
    if solution is None:
        out["errors"].append("不可解")
        return out
    out["solution"] = {
        "moves": solution.moves,
        "par_moves": len(solution.moves),
        "par_pushes": solution.optimal_pushes,
        "solution_pushes": solution.solution_pushes,
        "expanded": solution.expanded,
        "push_expanded": solution.push_expanded,
        "seconds": round(solution.seconds, 3),
    }
    if with_traps:
        out["traps"] = trap_profile(level, solver, solution.moves)
    return out


def trap_profile(level: sk.Level, solver: sk.Solver, moves: str) -> dict:
    """Walk the optimal solution. Before each of its pushes, try every legal push
    the player could make instead and count the ones that make the level
    unsolvable (irreversible mistakes = traps):

    * ``simple``: the box lands on a dead square (static analysis), i.e. an
      obvious mistake such as a corner or a wall without a target;
    * ``hidden``: looks fine locally but the search proves there is no way out.
    """
    width = level.width
    offsets = solver.offsets
    memo: dict[tuple[int, int], bool] = {}

    def solvable(mask: int, player: int) -> bool | None:
        _, region = solver.walk_distances(mask, player)
        key = (mask, min(region))
        if key not in memo:
            probe = copy.copy(solver)
            probe.level = dataclasses.replace(level, boxes=frozenset(sk.iter_bits(mask)), player=player)
            try:
                probe._solve_pushes(TRAP_MAX_STATES)
                memo[key] = True
            except sk.SearchLimitError:
                return None
            except RuntimeError:                         # queue exhausted: unsolvable
                memo[key] = False
        return memo[key]

    steps = []
    unknown = 0
    mask = sk.to_mask(level.boxes)
    player = level.player
    letters = {d[0]: i for i, d in enumerate(sk.DIRECTIONS)}
    for ch in moves:
        off = offsets[letters[ch.lower()]]
        if ch.isupper():
            dist, _ = solver.walk_distances(mask, player)
            step = {"legal": 0, "simple": 0, "hidden": 0, "bad": []}
            for box in sk.iter_bits(mask):
                for d, o in enumerate(offsets):
                    dest = box + o
                    if dist[box - o] < 0 or not solver.floor[dest] or (mask >> dest) & 1:
                        continue
                    step["legal"] += 1
                    if solver.dead[dest]:
                        kind = "simple"
                    else:
                        ok = solvable(mask ^ (1 << box) ^ (1 << dest), box)
                        if ok is None:
                            unknown += 1
                        if ok is not False:
                            continue
                        kind = "hidden"
                    step[kind] += 1
                    step["bad"].append([box % width, box // width, d, kind == "hidden"])
            steps.append(step)
            mask ^= (1 << (player + off)) ^ (1 << (player + 2 * off))
        player += off
    total = {k: sum(s[k] for s in steps) for k in ("legal", "simple", "hidden")}
    return {"steps": steps, "unknown": unknown, **total}


def run_worker() -> int:
    """Child-process entry: read {map, traps} from stdin, print the analysis."""
    request = json.load(sys.stdin)
    json.dump(analyze([str(r) for r in request["map"]], bool(request.get("traps"))), sys.stdout)
    return 0


def analyze_in_child(rows: list[str], with_traps: bool) -> dict:
    timeout = TRAP_TIMEOUT if with_traps else SOLVE_TIMEOUT
    try:
        proc = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--worker"],
            input=json.dumps({"map": rows, "traps": with_traps}),
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"errors": [f"求解超时（>{timeout:.0f} 秒）"], "warnings": []}
    if proc.returncode != 0:
        return {"errors": ["求解进程出错：" + proc.stderr.strip()[-400:]], "warnings": []}
    return json.loads(proc.stdout)


# --------------------------------------------------------------------------
# Level files
# --------------------------------------------------------------------------

def level_path(level_id: str) -> Path:
    if not ID_RE.match(level_id):
        raise ValueError(f"非法关卡 id：{level_id!r}")
    return LEVELS / f"{level_id}.json"


def list_levels() -> list[dict]:
    result = []
    for path in sorted(LEVELS.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            data = {"id": path.stem, "name": f"（读取失败：{exc}）", "map": []}
        result.append({"file": path.stem, "data": data})
    return result


def write_level(level_id: str, data: dict) -> None:
    data = dict(data)
    data["id"] = level_id
    level_path(level_id).write_text(sk.dump_level(data), encoding="utf-8")


def renumber() -> None:
    """Close gaps in the numeric ids (01, 02, 04 -> 01, 02, 03): the game shows
    ``id.to_int()`` as the level's roman numeral."""
    numbered = sorted((p for p in LEVELS.glob("*.json") if p.stem.isdigit()), key=lambda p: int(p.stem))
    for index, path in enumerate(numbered, start=1):
        new_id = f"{index:02d}"
        if path.stem != new_id:
            data = json.loads(path.read_text(encoding="utf-8"))
            path.unlink()
            write_level(new_id, data)


def next_id() -> str:
    numbers = [int(p.stem) for p in LEVELS.glob("*.json") if p.stem.isdigit()]
    return f"{max(numbers, default=0) + 1:02d}"


_missing_cache: dict[str, set[str]] = {}


def missing_glyphs(text: str) -> str:
    """Characters of ``text`` that the bundled font subset cannot draw."""
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        return ""
    if "cmap" not in _missing_cache:
        try:
            _missing_cache["cmap"] = {chr(c) for c in TTFont(FONT).getBestCmap()}
        except OSError:
            return ""
    cmap = _missing_cache["cmap"]
    return "".join(sorted({c for c in text if not c.isspace() and c not in cmap}))


def find_godot() -> str:
    for candidate in GODOT_CANDIDATES:
        if candidate and Path(candidate).exists():
            return candidate
    return ""


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

_write_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "LevelStudio/1"

    def log_message(self, fmt: str, *args) -> None:   # keep the terminal quiet
        pass

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload, status: int = 200) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def do_GET(self) -> None:
        if self.path in ("/", "/index.html"):
            self._send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/levels":
            self._json({"levels": list_levels(), "themes": THEMES, "godot": bool(find_godot())})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            route = {
                "/api/analyze": self.api_analyze,
                "/api/save": self.api_save,
                "/api/create": self.api_create,
                "/api/delete": self.api_delete,
                "/api/swap": self.api_swap,
                "/api/play": self.api_play,
            }.get(self.path)
            if route is None:
                self._json({"error": "not found"}, 404)
                return
            self._json(route(body))
        except (ValueError, OSError, KeyError) as exc:
            self._json({"error": str(exc)}, 400)

    # ---- routes ------------------------------------------------------------

    def api_analyze(self, body: dict) -> dict:
        result = analyze_in_child([str(r) for r in body["map"]], bool(body.get("traps")))
        missing = missing_glyphs(str(body.get("name", "")))
        if missing:
            result["warnings"].append(
                f"名称里的「{missing}」不在游戏字体子集中，会用系统字体显示；"
                "定稿后运行 tools/subset_fonts.py 重新子集化")
        return result

    def api_save(self, body: dict) -> dict:
        data = body["data"]
        if data.get("theme") not in THEMES:
            raise ValueError(f"未知主题：{data.get('theme')!r}")
        with _write_lock:
            write_level(body["id"], data)
        return {"ok": True}

    def api_create(self, body: dict) -> dict:
        with _write_lock:
            new_id = next_id()
            source = body.get("from")
            if source:
                data = json.loads(level_path(source).read_text(encoding="utf-8"))
                data["name"] = f"{data.get('name', '')}·副本"
            else:
                data = {
                    "format": 1, "name": "新庭院", "name_en": "New Courtyard",
                    "theme": THEMES[(int(new_id) - 1) % len(THEMES)] if new_id.isdigit() else "dawn",
                    "seed": random.randint(1000, 9999),
                    "par_moves": -1, "par_pushes": -1, "solution": "",
                    "map": ["#######", "#-----#", "#-@$-.#", "#-----#", "#######"],
                }
            write_level(new_id, data)
            data["id"] = new_id
        return {"id": new_id, "data": data}

    def api_delete(self, body: dict) -> dict:
        with _write_lock:
            level_path(body["id"]).unlink()
            renumber()
        return {"ok": True}

    def api_swap(self, body: dict) -> dict:
        """Swap two levels' positions: each file takes the other's id."""
        a, b = str(body["a"]), str(body["b"])
        with _write_lock:
            da = json.loads(level_path(a).read_text(encoding="utf-8"))
            db = json.loads(level_path(b).read_text(encoding="utf-8"))
            write_level(a, db)
            write_level(b, da)
        return {"ok": True}

    def api_play(self, body: dict) -> dict:
        level_id = str(body["id"])
        level_path(level_id)
        godot = find_godot()
        if not godot:
            raise ValueError("找不到 Godot；可用环境变量 GODOT 指定可执行文件路径")
        subprocess.Popen([godot, "--path", str(ROOT), "--", f"--level={level_id}"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        return {"ok": True}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Local web editor for the built-in levels.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true", help="do not open a browser tab")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.worker:
        return run_worker()
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"关卡工作台：{url}   （Ctrl+C 退出）")
    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
