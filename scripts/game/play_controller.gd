class_name PlayController
extends Node
## 关卡内的操作控制：键盘（含按住连走与输入缓冲）、鼠标点击寻路、撤销/重做。
## 逻辑状态在动画开始时即更新，胜利在该步动画结束后判定。

signal solved
signal counters_changed(moves: int, pushes: int)
signal restart_requested
signal pause_requested
signal hint_requested
signal view_toggle_requested

const DIR_ACTIONS: PackedStringArray = ["move_up", "move_right", "move_down", "move_left"]
const HOLD_DELAY := 0.2

var world: World
var board: BoardView
var state: SokobanState
var accepting := false

var _buffer := -1
var _path: Array[int] = []
var _held_dir := -1
var _held_time := 0.0
var _hover_screen := Vector2(-1, -1)


func begin(st: SokobanState, b: BoardView, w: World) -> void:
	state = st
	board = b
	world = w
	if not board.step_finished.is_connected(_on_step_finished):
		board.step_finished.connect(_on_step_finished)
	_buffer = -1
	_path.clear()
	_held_dir = -1
	accepting = true
	counters_changed.emit(state.moves, state.pushes)


func stop() -> void:
	accepting = false
	_path.clear()
	_buffer = -1
	if board:
		board.hide_cursor()


# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		pause_requested.emit()
		get_viewport().set_input_as_handled()
		return
	if not accepting:
		return
	for i in 4:
		if event.is_action_pressed(DIR_ACTIONS[i]):
			request_move(i)
			_held_dir = i
			_held_time = 0.0
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("undo", true):
		undo()
	elif event.is_action_pressed("redo", true):
		redo()
	elif event.is_action_pressed("restart"):
		restart_requested.emit()
	elif event.is_action_pressed("hint"):
		hint_requested.emit()
	elif event.is_action_pressed("toggle_view"):
		view_toggle_requested.emit()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_click(event.position)
	elif event is InputEventMouseMotion:
		_hover_screen = event.position
		_update_hover()


func _process(delta: float) -> void:
	if not accepting or board == null:
		return
	if _held_dir >= 0:
		if Input.is_action_pressed(DIR_ACTIONS[_held_dir]):
			_held_time += delta
		else:
			_held_dir = -1
	if board.is_busy():
		return
	if _buffer >= 0:
		var d := _buffer
		_buffer = -1
		_do_move(d)
	elif not _path.is_empty():
		_do_move(_path.pop_front())
	elif _held_dir >= 0 and _held_time >= HOLD_DELAY:
		_do_move(_held_dir)


func request_move(dir: int) -> void:
	_path.clear()
	if board.is_busy():
		_buffer = dir
	else:
		_do_move(dir)


func _do_move(dir: int) -> void:
	var r := state.move(dir)
	board.play(r)
	if r.moved:
		counters_changed.emit(state.moves, state.pushes)
	board.hide_cursor()


func undo() -> void:
	_path.clear()
	_buffer = -1
	if board.is_busy() or not state.can_undo():
		return
	var r := state.undo()
	board.play(r)
	counters_changed.emit(state.moves, state.pushes)


func redo() -> void:
	_path.clear()
	_buffer = -1
	if board.is_busy() or not state.can_redo():
		return
	var r := state.redo()
	board.play(r)
	counters_changed.emit(state.moves, state.pushes)


## 按 LURD 记谱自动执行（回放最优解 / 开发测试）。
func play_lurd(lurd: String) -> void:
	_path.clear()
	for ch in lurd:
		var d := SokobanState.DIR_CHARS.find(ch.to_lower())
		if d >= 0:
			_path.append(d)


func _on_step_finished(r: SokobanState.MoveResult) -> void:
	if r.moved and r.solved and not r.is_undo and accepting:
		accepting = false
		_path.clear()
		board.hide_cursor()
		solved.emit()
	elif accepting:
		_update_hover()


# ---------------------------------------------------------------------------
# 鼠标：拾取与点击寻路
# ---------------------------------------------------------------------------

## 返回 {cell: Vector2i, box: int}。箱子用包围盒精确拾取，其余投射到地面。
func _pick(screen_pos: Vector2) -> Dictionary:
	var cam := world.camera
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var best_box := -1
	var best_t := INF
	for i in state.boxes.size():
		var c := BoardView.cell_pos(state.boxes[i])
		var h := Props.BOX_SIZE * 0.5
		var aabb := AABB(c - Vector3(h, 0, h), Vector3(h * 2, Props.BOX_SIZE, h * 2))
		var hit: Variant = aabb.intersects_ray(from, dir)
		if hit != null:
			var t: float = (hit - from).length()
			if t < best_t:
				best_t = t
				best_box = i
	if best_box >= 0:
		return {"cell": state.boxes[best_box], "box": best_box}
	if absf(dir.y) < 1e-5:
		return {"cell": Vector2i(-999, -999), "box": -1}
	var t0 := -from.y / dir.y
	var p := from + dir * t0
	return {"cell": Vector2i(roundi(p.x), roundi(p.z)), "box": -1}


func _click(screen_pos: Vector2) -> void:
	var pick := _pick(screen_pos)
	var cell: Vector2i = pick["cell"]
	if pick["box"] >= 0:
		var diff := cell - state.player
		if absi(diff.x) + absi(diff.y) == 1:
			request_move(SokobanState.dir_from_vector(diff))
			return
		# 走到箱子旁边离玩家最近的空位（不自动推）
		var best: Array[int] = []
		for d in SokobanState.DIRS:
			var n: Vector2i = cell + d
			var path := Pathfinder.find_path(state, n)
			if not path.is_empty() and (best.is_empty() or path.size() < best.size()):
				best = path
		_path = best
		return
	if state.is_walkable(cell):
		var path := Pathfinder.find_path(state, cell)
		if not path.is_empty():
			_buffer = -1
			_path = path


func _update_hover() -> void:
	if not accepting or board.is_busy() or _hover_screen.x < 0:
		return
	var pick := _pick(_hover_screen)
	var cell: Vector2i = pick["cell"]
	if pick["box"] >= 0:
		var diff := cell - state.player
		if absi(diff.x) + absi(diff.y) == 1:
			board.show_cursor(cell, [] as Array[int])
			return
	if state.is_walkable(cell) and cell != state.player:
		var path := Pathfinder.find_path(state, cell)
		if not path.is_empty():
			board.show_cursor(cell, path)
			return
	board.hide_cursor()
