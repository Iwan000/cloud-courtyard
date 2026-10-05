class_name HintService
extends RefCounted
## 提示：在后台线程从当前局面求解，返回下一次推箱（行走路径 + 推动方向）。
## 若当前局面已无解（陷入死局），也会如实告知，引导玩家撤销。

var _task := -1
var _solver: SokobanSolver
var _key := ""
var _cache := {}


func request(state: SokobanState) -> void:
	if busy():
		return
	_key = state.snapshot_key()
	if _cache.has(_key):
		return
	# 玩家目前的操作恰好是已存最优解的前缀：直接用剩余部分作答，无需求解
	var played := state.history_lurd()
	var stored := state.level.solution
	if stored != "" and stored.begins_with(played) and played.length() < stored.length():
		_cache[_key] = _first_push(stored.substr(played.length()), SokobanSolver.Status.SOLVED)
		return
	_solver = SokobanSolver.new()
	_solver.max_msec = 15000
	var lvl := state.level
	var boxes := state.boxes.duplicate()
	var player := state.player
	_task = WorkerThreadPool.add_task(func(): _solver.solve_from(lvl, boxes, player), false, "hint")


func busy() -> bool:
	return _task >= 0 and not WorkerThreadPool.is_task_completed(_task)


## 结果：{status: SokobanSolver.Status, walk: Array[int], push_dir: int} 或空字典（未完成）。
func poll(state: SokobanState) -> Dictionary:
	var key := state.snapshot_key()
	if _cache.has(key):
		return _cache[key]
	if _task < 0 or busy() or key != _key:
		return {}
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var res := _first_push(_solver.solution, _solver.status)
	_cache[key] = res
	return res


## 从 LURD 解中取出第一次推箱之前的行走路径与推动方向。
static func _first_push(lurd: String, status: int) -> Dictionary:
	var res := {"status": status, "walk": [] as Array[int], "push_dir": -1}
	if status != SokobanSolver.Status.SOLVED:
		return res
	for ch in lurd:
		var d := SokobanState.DIR_CHARS.find(ch.to_lower())
		if ch == ch.to_upper():
			res["push_dir"] = d
			break
		(res["walk"] as Array[int]).append(d)
	return res


func cancel() -> void:
	if _solver:
		_solver.cancelled = true
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
