class_name SokobanState
extends RefCounted
## 推箱子的运行时状态与规则（纯逻辑，不依赖渲染）。
##
## 每次操作返回 MoveResult，表现层只根据 MoveResult 播放动画与音效。
## 箱子拥有稳定 id（下标），表现层用它对应 3D 节点。

enum Dir { UP, RIGHT, DOWN, LEFT }

## 网格方向：x 为列，y 为行。UP = 行号减一。
const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## LURD 记谱：小写为行走，大写为推箱。
const DIR_CHARS := "urdl"


class MoveResult:
	extends RefCounted
	var dir: int = -1
	var moved := false
	var is_undo := false
	var from := Vector2i.ZERO
	var to := Vector2i.ZERO
	## 被推动或造成阻挡的箱子 id，-1 表示无
	var box_id := -1
	var box_from := Vector2i.ZERO
	var box_to := Vector2i.ZERO
	## 受阻原因："" / "wall" / "box"
	var blocked := ""
	var box_entered_target := false
	var box_left_target := false
	var solved := false

	func pushed() -> bool:
		return moved and box_id >= 0


var level: LevelData
var player := Vector2i.ZERO
var boxes: Array[Vector2i] = []
var moves := 0
var pushes := 0

var _box_at: Dictionary = {}          # Vector2i -> box id
var _history: Array[Vector2i] = []    # x = dir, y = box id（-1 表示没推箱）
var _redo: Array[int] = []            # 可重做的方向


func _init(lvl: LevelData) -> void:
	level = lvl
	reset()


func reset() -> void:
	player = level.player
	boxes = level.boxes.duplicate()
	_rebuild_box_map()
	_history.clear()
	_redo.clear()
	moves = 0
	pushes = 0


func _rebuild_box_map() -> void:
	_box_at.clear()
	for i in boxes.size():
		_box_at[boxes[i]] = i


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func box_at(p: Vector2i) -> int:
	return _box_at.get(p, -1)


func is_walkable(p: Vector2i) -> bool:
	return level.is_floor(p) and not _box_at.has(p)


func is_solved() -> bool:
	if boxes.is_empty():
		return false
	for b in boxes:
		if not level.is_target(b):
			return false
	return true


func boxes_on_target() -> int:
	var n := 0
	for b in boxes:
		if level.is_target(b):
			n += 1
	return n


func can_undo() -> bool:
	return not _history.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


## 按 LURD 记谱输出本局操作历史。
func history_lurd() -> String:
	var s := ""
	for h in _history:
		var c := DIR_CHARS[h.x]
		s += c.to_upper() if h.y >= 0 else c
	return s


## 当前局面的指纹（用于求解提示缓存等）。
func snapshot_key() -> String:
	var sorted := boxes.duplicate()
	sorted.sort()
	return "%s|%s" % [player, sorted]


# ---------------------------------------------------------------------------
# 操作
# ---------------------------------------------------------------------------

func move(dir: int) -> MoveResult:
	var r := _apply(dir)
	if r.moved:
		_redo.clear()
	return r


func redo() -> MoveResult:
	if _redo.is_empty():
		return MoveResult.new()
	var dir: int = _redo.pop_back()
	return _apply(dir)


func undo() -> MoveResult:
	var r := MoveResult.new()
	r.is_undo = true
	if _history.is_empty():
		return r
	var h: Vector2i = _history.pop_back()
	var d: Vector2i = DIRS[h.x]
	r.dir = h.x
	r.moved = true
	r.from = player
	r.to = player - d
	if h.y >= 0:
		var box_id: int = h.y
		r.box_id = box_id
		r.box_from = boxes[box_id]
		r.box_to = boxes[box_id] - d
		r.box_left_target = level.is_target(r.box_from) and not level.is_target(r.box_to)
		r.box_entered_target = level.is_target(r.box_to) and not level.is_target(r.box_from)
		_box_at.erase(r.box_from)
		boxes[box_id] = r.box_to
		_box_at[r.box_to] = box_id
		pushes -= 1
	player = r.to
	moves -= 1
	_redo.append(h.x)
	r.solved = is_solved()
	return r


func _apply(dir: int) -> MoveResult:
	var r := MoveResult.new()
	r.dir = dir
	r.from = player
	var d: Vector2i = DIRS[dir]
	var next := player + d
	r.to = next
	if not level.is_floor(next):
		r.blocked = "wall"
		return r
	var box_id := box_at(next)
	if box_id >= 0:
		var dest := next + d
		r.box_id = box_id
		r.box_from = next
		r.box_to = dest
		if not level.is_floor(dest) or _box_at.has(dest):
			r.blocked = "box"
			return r
		_box_at.erase(next)
		boxes[box_id] = dest
		_box_at[dest] = box_id
		r.box_entered_target = level.is_target(dest) and not level.is_target(next)
		r.box_left_target = level.is_target(next) and not level.is_target(dest)
		pushes += 1
	player = next
	moves += 1
	r.moved = true
	_history.append(Vector2i(dir, box_id))
	r.solved = is_solved()
	return r


## 按 LURD 记谱执行一串操作，返回是否全部成功（用于测试与回放）。
func apply_lurd(lurd: String) -> bool:
	for ch in lurd:
		var dir := DIR_CHARS.find(ch.to_lower())
		if dir < 0:
			return false
		var r := move(dir)
		if not r.moved:
			return false
		# 记谱大小写必须与是否推箱一致
		if (ch == ch.to_upper()) != r.pushed():
			return false
	return true


static func dir_from_vector(v: Vector2i) -> int:
	return DIRS.find(v)
