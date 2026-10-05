extends Node
## 端到端冒烟测试（真实游戏流程）：
##   godot --headless --path . --fixed-fps 60 -- --smoke
## 依次进入每个内置关卡，用求解器得到的最优解自动通关，确认进入结算；
## 再进入编辑器执行一组典型操作并试玩。全部通过时退出码为 0。

var main: Node
var _failures: Array[String] = []


func _ready() -> void:
	main = get_parent()
	_run.call_deferred()


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		_failures.append(msg)


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var t := 0.0
	while not cond.call():
		await get_tree().process_frame
		t += get_process_delta_time()
		if t > timeout_s:
			return false
	return true


func _run() -> void:
	await get_tree().create_timer(0.5).timeout
	print("[smoke] built-in levels: ", Game.builtin.size())
	_check(Game.builtin.size() >= 1, "built-in levels loaded")
	for lvl in Game.builtin:
		await _play_through(lvl)
	await _editor_flow()
	print("[smoke] %s" % ("PASSED" if _failures.is_empty() else "FAILED: %s" % [_failures]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _play_through(lvl: LevelData) -> void:
	print("[smoke] level ", lvl.id, " ", lvl.name)
	main.play_level(lvl)
	var ready := await _wait_until(func(): return main.controller.accepting, 20.0)
	_check(ready, "%s intro finished, input enabled" % lvl.id)
	var solver := SokobanSolver.new()
	solver.solve(lvl)
	_check(solver.status == SokobanSolver.Status.SOLVED, "%s solvable (%d moves)" % [lvl.id, solver.moves])
	main.board.speed = 3.0
	main.controller.play_lurd(solver.solution)
	var done := await _wait_until(func(): return main.screen == main.Screen.COMPLETE, 120.0)
	_check(done, "%s completed via solution playback" % lvl.id)
	_check(main.state.moves == solver.moves, "%s move counter %d == %d" % [lvl.id, main.state.moves, solver.moves])
	_check(Game.is_completed(lvl.id), "%s progress recorded" % lvl.id)
	main.board.speed = 1.0
	await _wait_until(func(): return main.screen_node is CompletePanel, 10.0)
	_check(main.screen_node is CompletePanel, "%s completion panel shown" % lvl.id)


func _editor_flow() -> void:
	print("[smoke] editor")
	main.go_editor(null)
	await get_tree().process_frame
	var ed: LevelEditor = main.editor
	_check(ed != null, "editor opened")
	# 墙 → 地板 → 箱子 → 印记 → 旅人：在空白处画一块新区域
	ed._set_tool(LevelEditor.Tool.FLOOR)
	ed._begin_stroke(Vector2i(1, 6), false, false)
	ed._end_stroke(Vector2i(1, 6))
	_check(ed.lvl.is_floor(Vector2i(1, 6)), "paint floor")
	ed._undo()
	_check(not ed.lvl.is_floor(Vector2i(1, 6)), "undo stroke")
	ed._redo_action()
	_check(ed.lvl.is_floor(Vector2i(1, 6)), "redo stroke")
	ed._auto_wall()
	_check(ed.lvl.is_wall(Vector2i(0, 6)), "auto wall encloses new floor")
	ed._resize(Vector2i(1, 1))
	_check(ed.lvl.width == 11 and ed.lvl.height == 9, "resize canvas")
	ed._set_theme("night")
	_check(ed.lvl.theme == "night", "change theme")
	ed._start_solve()
	var solved := await _wait_until(func(): return ed._solver_task < 0, 20.0)
	_check(solved and not ed._solve_result.is_empty() and ed._solve_result["status"] == SokobanSolver.Status.SOLVED, "editor solver")
	var xsb := ed.lvl.trimmed().to_xsb()
	var back := LevelData.from_xsb(xsb)
	_check(back.boxes.size() == ed.lvl.boxes.size(), "xsb export/import keeps boxes")
	ed._test()
	var playing := await _wait_until(func(): return main.screen == main.Screen.PLAY and main.controller.accepting, 20.0)
	_check(playing, "test play from editor")
	main.go_editor(null)
	await get_tree().process_frame
	_check(main.editor == ed and ed.visible, "editor resumed with state after test play")
	_check(ed.lvl.theme == "night" and ed._history.size() > 0, "editor history kept")
