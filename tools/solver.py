#!/usr/bin/env python3
"""Offline Sokoban solver and level validator for Cloud Courtyard (云上庭).

The game ships with its own GDScript solver; this script is the offline twin
used while designing levels. For every level file it

1. parses and validates the map (enclosure, one player, boxes == targets,
   nothing unreachable, no box on a dead square, not already solved),
2. finds a **move-optimal** solution with A* (expansion unit = one push),
3. finds the **push-optimal** push count with a second A*,
4. replays the solution with an independent move simulator, and
5. optionally (``--write``) stores ``par_moves``, ``par_pushes`` and
   ``solution`` back into the JSON file.

Map format (XSB-compatible, one string per row)::

    #  wall               .  target            @  player
    -  floor (also _)     $  box               +  player on target
       (space) void       *  box on target

A space is floor only when the player can reach it by flood fill through
non-wall cells; otherwise it is void (outside the building). Rows may have
different lengths. Grid coordinates: x = column, y = row.

Solutions use LURD notation: lowercase letters walk, uppercase letters push;
``u``/``d`` change the row by -1/+1, ``l``/``r`` change the column by -1/+1.

Search outline
--------------
* State = (set of box cells, player cell right after the last push).
* From a state, a BFS gives the player's walking distance to every cell
  (boxes block). Each reachable push whose destination is free floor and not
  a dead square yields a successor with cost ``walk + 1``.
* Heuristic = sum over boxes of the minimum number of pushes to any target,
  ignoring other boxes and the player. A push changes it by at most 1 and
  costs at least 1 move, so it is consistent and A* returns optimal moves.
* Dead squares are found by "pulling" a box backwards from every target;
  cells a box can never be pulled to can never reach a target.
* Pushes that create a 2x2 block of walls/boxes containing a box that is
  not on a target are pruned (none of those boxes can ever move again).

Usage::

    python3 tools/solver.py levels/*.json            # report
    python3 tools/solver.py levels/*.json --write    # store par values
    python3 tools/solver.py levels/*.json --check    # fail if stored values are stale
"""

from __future__ import annotations

import argparse
import heapq
import json
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

# Direction table shared by the solver: (LURD letter, dx, dy).
# The order also fixes tie-breaking, so solutions are deterministic.
DIRECTIONS: tuple[tuple[str, int, int], ...] = (
    ("u", 0, -1),
    ("d", 0, 1),
    ("l", -1, 0),
    ("r", 1, 0),
)

UNREACHABLE = 1 << 30
DEFAULT_MAX_STATES = 2_000_000

# Soft design limits for built-in levels (the in-game solver must stay fast).
DESIGN_MAX_COLS = 12
DESIGN_MAX_ROWS = 10
DESIGN_MAX_FLOOR = 45

# Canonical key order for level files; unknown keys are kept after these.
KEY_ORDER: tuple[str, ...] = (
    "format", "id", "name", "name_en", "theme", "seed",
    "par_moves", "par_pushes", "solution", "map",
)


class LevelError(ValueError):
    """The map cannot be parsed or breaks a hard level rule."""


class SimulationError(ValueError):
    """A move string is illegal on the level it is replayed on."""


class SearchLimitError(RuntimeError):
    """The search expanded more states than allowed."""


# --------------------------------------------------------------------------
# Level model and parsing
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Level:
    """Static layout plus the initial dynamic state. Cells are ``y * width + x``."""

    width: int
    height: int
    floor: tuple[bool, ...]          # walkable cells (targets included)
    targets: frozenset[int]
    boxes: frozenset[int]
    player: int
    warnings: tuple[str, ...] = ()

    def xy(self, cell: int) -> tuple[int, int]:
        return cell % self.width, cell // self.width

    def is_floor(self, x: int, y: int) -> bool:
        return 0 <= x < self.width and 0 <= y < self.height and self.floor[y * self.width + x]

    @property
    def floor_count(self) -> int:
        return sum(self.floor)


def parse_map(rows: list[str]) -> Level:
    """Parse XSB-style rows into a :class:`Level`, applying the flood-fill rule."""
    rows = [row.rstrip(" ") for row in rows]
    height = len(rows)
    width = max((len(row) for row in rows), default=0)
    if width == 0:
        raise LevelError("map is empty")
    grid = [row.ljust(width) for row in rows]

    walls: set[int] = set()
    marked: set[int] = set()      # cells explicitly drawn as floor / box / target
    spaces: set[int] = set()
    targets: set[int] = set()
    boxes: set[int] = set()
    players: list[int] = []

    for y, row in enumerate(grid):
        for x, ch in enumerate(row):
            cell = y * width + x
            if ch == "#":
                walls.add(cell)
            elif ch == " ":
                spaces.add(cell)
            elif ch in "-_.$*@+":
                marked.add(cell)
                if ch in ".*+":
                    targets.add(cell)
                if ch in "$*":
                    boxes.add(cell)
                if ch in "@+":
                    players.append(cell)
            else:
                raise LevelError(f"unknown map character {ch!r} at x={x}, y={y}")

    if len(players) != 1:
        raise LevelError(f"expected exactly one player, found {len(players)}")
    player = players[0]

    # Flood fill from the player through every non-wall cell. Touching the
    # grid border means the play area is not enclosed by walls.
    region = {player}
    queue = deque([player])
    while queue:
        cell = queue.popleft()
        x, y = cell % width, cell // width
        for _, dx, dy in DIRECTIONS:
            nx, ny = x + dx, y + dy
            if not (0 <= nx < width and 0 <= ny < height):
                raise LevelError(f"play area is not enclosed by walls (leaks at x={x}, y={y})")
            nxt = ny * width + nx
            if nxt not in walls and nxt not in region:
                region.add(nxt)
                queue.append(nxt)

    stray = sorted(marked - region)
    if stray:
        where = ", ".join(f"({c % width},{c // width})" for c in stray[:6])
        raise LevelError(f"cells not reachable from the player: {where}")

    warnings: list[str] = []
    inner_spaces = region & spaces
    if inner_spaces:
        warnings.append(f"{len(inner_spaces)} interior floor cell(s) written as spaces; use '-'")

    floor = tuple(cell in region for cell in range(width * height))
    return Level(width, height, floor, frozenset(targets), frozenset(boxes), player, tuple(warnings))


# --------------------------------------------------------------------------
# Solver
# --------------------------------------------------------------------------

def iter_bits(mask: int) -> Iterator[int]:
    """Yield the indices of set bits (box cells) in ascending order."""
    while mask:
        low = mask & -mask
        yield low.bit_length() - 1
        mask ^= low


def to_mask(cells: frozenset[int] | set[int]) -> int:
    mask = 0
    for cell in cells:
        mask |= 1 << cell
    return mask


@dataclass
class Solution:
    moves: str                 # LURD string of a move-optimal solution
    solution_pushes: int       # pushes contained in that string
    optimal_pushes: int        # push-optimal push count (may be lower)
    expanded: int              # states expanded by the move-optimal search
    push_expanded: int         # states expanded by the push-optimal search
    seconds: float = 0.0


class Solver:
    """A* Sokoban solver over push states with dead-square and 2x2 pruning."""

    def __init__(self, level: Level) -> None:
        self.level = level
        self.width = level.width
        self.floor = level.floor
        self.offsets = tuple(dx + dy * level.width for _, dx, dy in DIRECTIONS)
        self.target_mask = to_mask(level.targets)
        self.push_distance = self._min_push_distances()
        self.dead = tuple(f and d >= UNREACHABLE for f, d in zip(self.floor, self.push_distance))

    # ---- static analysis ------------------------------------------------

    def _min_push_distances(self) -> list[int]:
        """Fewest pushes from each cell to the nearest target, ignoring other boxes.

        Multi-source BFS from all targets using reverse moves ("pulls"): a box
        on ``c`` can be pulled to ``c + o`` when the player can stand on
        ``c + o`` and step back to ``c + 2o``.
        """
        dist = [UNREACHABLE] * len(self.floor)
        queue: deque[int] = deque()
        for target in self.level.targets:
            dist[target] = 0
            queue.append(target)
        while queue:
            cell = queue.popleft()
            for off in self.offsets:
                nxt = cell + off
                if self.floor[nxt] and self.floor[nxt + off] and dist[nxt] == UNREACHABLE:
                    dist[nxt] = dist[cell] + 1
                    queue.append(nxt)
        return dist

    def dead_cells(self) -> list[int]:
        return [cell for cell, dead in enumerate(self.dead) if dead]

    def heuristic(self, mask: int) -> int:
        return sum(self.push_distance[box] for box in iter_bits(mask))

    # ---- per-state helpers ----------------------------------------------

    def walk_distances(self, mask: int, start: int) -> tuple[list[int], list[int]]:
        """BFS of the player with boxes as obstacles -> (distance per cell, visit order)."""
        dist = [-1] * len(self.floor)
        dist[start] = 0
        order = [start]
        queue = deque(order)
        floor = self.floor
        while queue:
            cell = queue.popleft()
            step = dist[cell] + 1
            for off in self.offsets:
                nxt = cell + off
                if dist[nxt] < 0 and floor[nxt] and not (mask >> nxt) & 1:
                    dist[nxt] = step
                    order.append(nxt)
                    queue.append(nxt)
        return dist, order

    def walk_path(self, mask: int, start: int, goal: int) -> str:
        """Shortest walk (lowercase LURD) from ``start`` to ``goal`` without pushing."""
        if start == goal:
            return ""
        came_from: dict[int, tuple[int, str]] = {start: (start, "")}
        queue = deque([start])
        while queue:
            cell = queue.popleft()
            for (letter, _, _), off in zip(DIRECTIONS, self.offsets):
                nxt = cell + off
                if nxt in came_from or not self.floor[nxt] or (mask >> nxt) & 1:
                    continue
                came_from[nxt] = (cell, letter)
                if nxt == goal:
                    letters = []
                    while nxt != start:
                        nxt, letter = came_from[nxt]
                        letters.append(letter)
                    return "".join(reversed(letters))
                queue.append(nxt)
        raise RuntimeError("walk_path: goal is not reachable")

    def is_frozen_2x2(self, mask: int, cell: int) -> bool:
        """True if ``cell`` is part of a 2x2 block of walls/boxes holding an unplaced box."""
        w = self.width
        for corner in (cell, cell - 1, cell - w, cell - w - 1):
            block = (corner, corner + 1, corner + w, corner + w + 1)
            if all(not self.floor[c] or (mask >> c) & 1 for c in block):
                if any((mask >> c) & 1 and not (self.target_mask >> c) & 1 for c in block):
                    return True
        return False

    def pushes(self, mask: int, dist: list[int]) -> Iterator[tuple[int, int, int]]:
        """Yield ``(box, direction index, new mask)`` for every legal, non-dead push."""
        for box in iter_bits(mask):
            for d, off in enumerate(self.offsets):
                dest = box + off
                if dist[box - off] < 0 or not self.floor[dest] or (mask >> dest) & 1:
                    continue
                if self.dead[dest]:
                    continue
                new_mask = mask ^ (1 << box) ^ (1 << dest)
                if self.is_frozen_2x2(new_mask, dest):
                    continue
                yield box, d, new_mask

    # ---- searches -------------------------------------------------------

    def solve(self, max_states: int = DEFAULT_MAX_STATES) -> Solution | None:
        """Move-optimal and push-optimal solve. Returns ``None`` if unsolvable."""
        started = time.perf_counter()
        found = self._solve_moves(max_states)
        if found is None:
            return None
        pushes, expanded = found
        moves = self.render(pushes)
        optimal_pushes, push_expanded = self._solve_pushes(max_states)
        return Solution(
            moves=moves,
            solution_pushes=len(pushes),
            optimal_pushes=optimal_pushes,
            expanded=expanded,
            push_expanded=push_expanded,
            seconds=time.perf_counter() - started,
        )

    def _solve_moves(self, max_states: int) -> tuple[list[tuple[int, int]], int] | None:
        """A* on (boxes, player) with cost = walk + push moves."""
        start_mask = to_mask(self.level.boxes)
        h0 = self.heuristic(start_mask)
        if h0 >= UNREACHABLE:
            return None
        start = (start_mask, self.level.player)
        best_g = {start: 0}
        parent: dict[tuple[int, int], tuple[tuple[int, int], int, int]] = {}
        heap = [(h0, 0, 0, start_mask, self.level.player)]  # (f, -g, tiebreak, mask, player)
        counter = 0
        expanded = 0
        while heap:
            f, neg_g, _, mask, player = heapq.heappop(heap)
            g = -neg_g
            key = (mask, player)
            if g > best_g[key]:
                continue                                     # stale queue entry
            if mask == self.target_mask:
                pushes = []
                while key in parent:
                    key, box, d = parent[key]
                    pushes.append((box, d))
                pushes.reverse()
                return pushes, expanded
            expanded += 1
            if expanded > max_states:
                raise SearchLimitError(f"more than {max_states} states expanded")
            h = f - g
            dist, _ = self.walk_distances(mask, player)
            for box, d, new_mask in self.pushes(mask, dist):
                off = self.offsets[d]
                g2 = g + dist[box - off] + 1
                key2 = (new_mask, box)
                if g2 >= best_g.get(key2, UNREACHABLE):
                    continue
                best_g[key2] = g2
                parent[key2] = (key, box, d)
                h2 = h - self.push_distance[box] + self.push_distance[box + off]
                counter -= 1                                 # LIFO among equal (f, g)
                heapq.heappush(heap, (g2 + h2, -g2, counter, new_mask, box))
        return None

    def _solve_pushes(self, max_states: int) -> tuple[int, int]:
        """A* counting pushes only; player position is normalised to its region."""
        start_mask = to_mask(self.level.boxes)
        heap = [(self.heuristic(start_mask), 0, 0, start_mask, self.level.player)]
        best_g = {(start_mask, self.level.player): 0}
        closed: set[tuple[int, int]] = set()
        counter = 0
        while heap:
            f, g, _, mask, player = heapq.heappop(heap)
            if mask == self.target_mask:
                return g, len(closed)
            dist, region = self.walk_distances(mask, player)
            key = (mask, min(region))
            if key in closed:
                continue
            closed.add(key)
            if len(closed) > max_states:
                raise SearchLimitError(f"more than {max_states} states expanded (push search)")
            h = f - g
            for box, d, new_mask in self.pushes(mask, dist):
                off = self.offsets[d]
                raw = (new_mask, box)
                if g + 1 >= best_g.get(raw, UNREACHABLE):
                    continue
                best_g[raw] = g + 1
                h2 = h - self.push_distance[box] + self.push_distance[box + off]
                counter -= 1
                heapq.heappush(heap, (g + 1 + h2, g + 1, counter, new_mask, box))
        raise RuntimeError("push search failed on a level the move search solved")

    def render(self, pushes: list[tuple[int, int]]) -> str:
        """Turn a push sequence into a full LURD move string."""
        mask = to_mask(self.level.boxes)
        player = self.level.player
        parts: list[str] = []
        for box, d in pushes:
            off = self.offsets[d]
            parts.append(self.walk_path(mask, player, box - off))
            parts.append(DIRECTIONS[d][0].upper())
            mask ^= (1 << box) ^ (1 << (box + off))
            player = box
        return "".join(parts)


# --------------------------------------------------------------------------
# Validation and independent replay
# --------------------------------------------------------------------------

def validate(level: Level, solver: Solver) -> tuple[list[str], list[str]]:
    """Return ``(errors, warnings)`` for the design rules of built-in levels."""
    errors: list[str] = []
    warnings = list(level.warnings)
    if not level.boxes:
        errors.append("level has no boxes")
    if len(level.boxes) != len(level.targets):
        errors.append(f"{len(level.boxes)} boxes but {len(level.targets)} targets")
    if level.boxes and level.boxes == level.targets:
        errors.append("level is already solved")
    for box in sorted(level.boxes):
        if solver.dead[box]:
            errors.append("box starts on a dead square at x=%d, y=%d" % level.xy(box))
    if level.width > DESIGN_MAX_COLS or level.height > DESIGN_MAX_ROWS:
        warnings.append(f"grid {level.width}x{level.height} exceeds {DESIGN_MAX_COLS}x{DESIGN_MAX_ROWS}")
    if level.floor_count > DESIGN_MAX_FLOOR:
        warnings.append(f"{level.floor_count} floor cells exceed {DESIGN_MAX_FLOOR}")
    return errors, warnings


def simulate(level: Level, moves: str) -> tuple[bool, int]:
    """Replay ``moves`` with plain coordinates; return ``(solved, pushes)``.

    Deliberately independent of :class:`Solver` so it can check its output.
    """
    steps = {"u": (0, -1), "d": (0, 1), "l": (-1, 0), "r": (1, 0)}
    boxes = {level.xy(c) for c in level.boxes}
    targets = {level.xy(c) for c in level.targets}
    x, y = level.xy(level.player)
    pushes = 0
    for i, ch in enumerate(moves, start=1):
        if ch.lower() not in steps:
            raise SimulationError(f"move {i}: invalid character {ch!r}")
        dx, dy = steps[ch.lower()]
        nx, ny = x + dx, y + dy
        if not level.is_floor(nx, ny):
            raise SimulationError(f"move {i} ({ch}): walks into a wall")
        if (nx, ny) in boxes:
            if ch.islower():
                raise SimulationError(f"move {i} ({ch}): lowercase move would push a box")
            bx, by = nx + dx, ny + dy
            if not level.is_floor(bx, by) or (bx, by) in boxes:
                raise SimulationError(f"move {i} ({ch}): box is blocked")
            boxes.remove((nx, ny))
            boxes.add((bx, by))
            pushes += 1
        elif ch.isupper():
            raise SimulationError(f"move {i} ({ch}): uppercase move but no box to push")
        x, y = nx, ny
    return boxes == targets, pushes


# --------------------------------------------------------------------------
# Level files
# --------------------------------------------------------------------------

def load_level_file(path: Path) -> dict:
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data.get("map"), list):
        raise LevelError("missing 'map' array")
    return data


def dump_level(data: dict) -> str:
    """Serialise a level dict in canonical key order (2-space indent, one row per line)."""
    ordered = {key: data[key] for key in KEY_ORDER if key in data}
    ordered.update((key, value) for key, value in data.items() if key not in ordered)
    return json.dumps(ordered, indent=2, ensure_ascii=False) + "\n"


@dataclass
class Report:
    path: Path
    ok: bool = True
    lines: list[str] = field(default_factory=list)
    stale: bool = False


def process(path: Path, args: argparse.Namespace) -> Report:
    report = Report(path)

    def fail(message: str) -> Report:
        report.ok = False
        report.lines.append(f"  ERROR    {message}")
        return report

    try:
        data = load_level_file(path)
        level = parse_map(data["map"])
    except (OSError, json.JSONDecodeError, LevelError) as exc:
        report.lines.append(str(path))
        return fail(str(exc))

    title = " · ".join(str(data[k]) for k in ("name", "name_en") if data.get(k))
    report.lines.append(f"{path}  [{data.get('id', '?')}] {title}")
    solver = Solver(level)
    errors, warnings = validate(level, solver)
    report.lines.append(
        f"  layout   {level.width}x{level.height} grid, {level.floor_count} floor cells, "
        f"{len(level.boxes)} boxes, {len(solver.dead_cells())} dead squares"
    )
    for warning in warnings:
        report.lines.append(f"  warning  {warning}")
    if errors:
        for error in errors[:-1]:
            report.lines.append(f"  ERROR    {error}")
        return fail(errors[-1])

    try:
        solution = solver.solve(args.max_states)
    except SearchLimitError as exc:
        return fail(f"search limit reached: {exc}")
    if solution is None:
        return fail("level is unsolvable")

    try:
        solved, sim_pushes = simulate(level, solution.moves)
    except SimulationError as exc:
        return fail(f"solver produced an illegal move string: {exc}")
    report.lines.append(
        f"  optimal  {len(solution.moves)} moves, {solution.optimal_pushes} pushes"
        + (f" (move-optimal line uses {solution.solution_pushes} pushes)"
           if solution.solution_pushes != solution.optimal_pushes else "")
    )
    report.lines.append(
        f"  search   {solution.expanded} states expanded "
        f"({solution.push_expanded} in push search), {solution.seconds:.2f} s"
    )
    if not solved or sim_pushes != solution.solution_pushes:
        return fail("simulated solution does not solve the level")
    report.lines.append("  replay   OK")
    if args.verbose:
        report.lines.append(f"  solution {solution.moves}")

    stored = data.get("solution")
    if isinstance(stored, str) and stored and stored != solution.moves:
        try:
            stored_ok, _ = simulate(level, stored)
            note = f"{len(stored)} moves, " + ("solves the level" if stored_ok else "does not solve the level")
        except SimulationError as exc:
            note = str(exc)
        report.lines.append(f"  stored   solution differs ({note})")

    computed = {
        "par_moves": len(solution.moves),
        "par_pushes": solution.optimal_pushes,
        "solution": solution.moves,
    }
    changed = [key for key, value in computed.items() if data.get(key) != value]
    if changed:
        report.stale = True
        if args.write:
            data.update(computed)
            path.write_text(dump_level(data), encoding="utf-8")
            report.lines.append(f"  written  {', '.join(changed)}")
        else:
            report.lines.append(f"  stale    {', '.join(changed)} (run with --write)")
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate and optimally solve Cloud Courtyard level files.",
        epilog="example: python3 tools/solver.py levels/*.json --write",
    )
    parser.add_argument("files", nargs="+", type=Path, help="level JSON files")
    parser.add_argument("--write", action="store_true",
                        help="store par_moves, par_pushes and solution in each file")
    parser.add_argument("--check", action="store_true",
                        help="exit with status 1 if stored par values or solution are stale")
    parser.add_argument("--max-states", type=int, default=DEFAULT_MAX_STATES,
                        help=f"expansion limit per search (default {DEFAULT_MAX_STATES})")
    parser.add_argument("-v", "--verbose", action="store_true", help="print each solution")
    args = parser.parse_args(argv)

    reports = [process(path, args) for path in args.files]
    for report in reports:
        print("\n".join(report.lines) or str(report.path))
        print()
    failed = [r for r in reports if not r.ok]
    stale = [r for r in reports if r.stale and not args.write]
    print(f"{len(reports)} level(s): {len(reports) - len(failed)} OK, {len(failed)} failed"
          + (f", {len(stale)} stale" if stale else ""))
    if failed or (args.check and stale):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
