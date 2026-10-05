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
	_solver = SokobanSolver.new()
	_solver.max_msec = 8000
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
	var res := {"status": _solver.status, "walk": [] as Array[int], "push_dir": -1}
	if _solver.status == SokobanSolver.Status.SOLVED:
		for ch in _solver.solution:
			var d := SokobanState.DIR_CHARS.find(ch.to_lower())
			if ch == ch.to_upper():
				res["push_dir"] = d
				break
			(res["walk"] as Array[int]).append(d)
	_cache[key] = res
	return res


func cancel() -> void:
	if _solver:
		_solver.cancelled = true
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
