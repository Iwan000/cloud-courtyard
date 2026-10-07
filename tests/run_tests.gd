extends SceneTree
## Headless 单元测试入口：
##   godot --headless --path . --script res://tests/run_tests.gd
## 全部通过时退出码为 0。

var _passed := 0
var _failed := 0
var _current := ""


func _init() -> void:
	var tests := [
		"test_parse_rows",
		"test_xsb_flood_fill",
		"test_json_roundtrip",
		"test_move_and_push",
		"test_blocked",
		"test_undo_redo",
		"test_win_detection",
		"test_lurd_replay",
		"test_pathfinder",
		"test_validate",
		"test_resize_trim",
		"test_solver_small",
		"test_solver_unsolvable",
		"test_grades",
		"test_builtin_levels",
	]
	for t in tests:
		_current = t
		call(t)
	print("")
	print("==== %d passed, %d failed ====" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		printerr("[FAIL] %s: %s" % [_current, msg])


func lvl(rows: Array) -> LevelData:
	return LevelData.from_rows(PackedStringArray(rows))


# ---------------------------------------------------------------------------

func test_parse_rows() -> void:
	var l := lvl([
		"#####",
		"#@$.#",
		"#####",
	])
	check(l.width == 5 and l.height == 3, "size")
	check(l.player == Vector2i(1, 1), "player")
	check(l.boxes.size() == 1 and l.boxes[0] == Vector2i(2, 1), "boxes")
	check(l.is_target(Vector2i(3, 1)), "target")
	check(l.is_wall(Vector2i(0, 0)), "wall")


func test_xsb_flood_fill() -> void:
	# 经典 XSB：空格在墙内为地板，在墙外为虚空
	var l := LevelData.from_xsb("  ####\n###  #\n#@$ .#\n######")
	check(l.get_cell(Vector2i(0, 0)) == LevelData.Cell.VOID, "outside is void")
	check(l.is_floor(Vector2i(3, 1)), "inside space is floor")
	check(l.is_floor(Vector2i(3, 2)), "inside space is floor 2")
	# 导出标准 XSB 再导入，地图应一致
	var again := LevelData.from_xsb(l.to_xsb())
	check(again.to_rows() == l.to_rows(), "xsb roundtrip")


func test_json_roundtrip() -> void:
	var l := lvl(["######", "#@$-.#", "######"])
	l.id = "07"
	l.name = "测试"
	l.name_en = "Test"
	l.theme = "dusk"
	l.decor_seed = 42
	var parsed: Variant = JSON.parse_string(l.to_json_string())
	check(typeof(parsed) == TYPE_DICTIONARY, "json parses")
	var back := LevelData.from_dict(parsed)
	check(back.to_rows() == l.to_rows(), "map roundtrip")
	check(back.name == "测试" and back.theme == "dusk" and back.decor_seed == 42, "meta roundtrip")
	check(not parsed.has("grades"), "grades omitted when unset")
	l.grades = PackedInt32Array([5, 9])
	back = LevelData.from_dict(JSON.parse_string(l.to_json_string()))
	check(back.grades == PackedInt32Array([5, 9]), "grades roundtrip")


func test_move_and_push() -> void:
	var s := SokobanState.new(lvl(["######", "#@$-.#", "######"]))
	var r := s.move(SokobanState.Dir.RIGHT)
	check(r.moved and r.pushed(), "push moved")
	check(r.box_from == Vector2i(2, 1) and r.box_to == Vector2i(3, 1), "box positions")
	check(s.player == Vector2i(2, 1), "player follows")
	check(s.moves == 1 and s.pushes == 1, "counters")
	r = s.move(SokobanState.Dir.RIGHT)
	check(r.box_entered_target, "entered target")
	check(r.solved and s.is_solved(), "solved")


func test_blocked() -> void:
	var s := SokobanState.new(lvl(["#####", "#@$$#", "#---#", "#####"]))
	var r := s.move(SokobanState.Dir.RIGHT)
	check(not r.moved and r.blocked == "box", "box blocked by box")
	r = s.move(SokobanState.Dir.UP)
	check(not r.moved and r.blocked == "wall", "wall blocked")
	check(s.moves == 0, "no move counted")


func test_undo_redo() -> void:
	var s := SokobanState.new(lvl(["#######", "#@$--.#", "#######"]))
	s.move(SokobanState.Dir.RIGHT)
	s.move(SokobanState.Dir.RIGHT)
	check(s.boxes[0] == Vector2i(4, 1), "pushed twice")
	var u := s.undo()
	check(u.is_undo and u.box_id == 0 and u.box_to == Vector2i(3, 1), "undo moves box back")
	check(s.player == Vector2i(2, 1) and s.moves == 1 and s.pushes == 1, "undo state")
	var r := s.redo()
	check(r.moved and s.boxes[0] == Vector2i(4, 1), "redo")
	s.undo()
	s.undo()
	check(s.player == Vector2i(1, 1) and s.boxes[0] == Vector2i(2, 1), "back to start")
	check(not s.can_undo() and s.can_redo(), "stacks")
	s.move(SokobanState.Dir.DOWN)  # 受阻不清空重做栈
	check(s.can_redo(), "blocked move keeps redo")


func test_win_detection() -> void:
	var s := SokobanState.new(lvl(["######", "#@$*.#", "######"]))
	check(not s.is_solved(), "not solved at start")
	check(s.boxes_on_target() == 1, "one on target")


func test_lurd_replay() -> void:
	var s := SokobanState.new(lvl(["#######", "#@-$-.#", "#######"]))
	check(s.apply_lurd("rRR"), "replay ok")
	check(s.is_solved(), "replay solves")
	check(s.history_lurd() == "rRR", "history lurd")
	var s2 := SokobanState.new(lvl(["#######", "#@-$-.#", "#######"]))
	check(not s2.apply_lurd("RRR"), "case must match pushes")


func test_pathfinder() -> void:
	var s := SokobanState.new(lvl([
		"######",
		"#@-#-#",
		"#-$--#",
		"#----#",
		"######",
	]))
	var path := Pathfinder.find_path(s, Vector2i(4, 1))
	check(path.size() == 7, "path around box and wall (got %d)" % path.size())
	var s3 := SokobanState.new(s.level)
	for d in path:
		var r := s3.move(d)
		check(r.moved and not r.pushed(), "path never pushes")
	check(s3.player == Vector2i(4, 1), "reached goal")
	check(Pathfinder.find_path(s, Vector2i(3, 1)).is_empty(), "wall unreachable")


func test_validate() -> void:
	var good := lvl(["######", "#@$-.#", "######"]).validate()
	check(good.errors.is_empty(), "valid level: %s" % [good.errors])
	var mismatch := lvl(["######", "#@$$.#", "######"]).validate()
	check(not mismatch.errors.is_empty(), "box/target mismatch")
	var corner := lvl(["#####", "#$-.#", "#-@-#", "#####"]).validate()
	check(not corner.errors.is_empty(), "dead corner box")
	var open := lvl(["-@$.-"]).validate()
	check(open.errors.is_empty() and not open.warnings.is_empty(), "open edge is warning only")


func test_resize_trim() -> void:
	var l := lvl(["######", "#@$-.#", "######"])
	var big := l.resized(10, 7, Vector2i(2, 2))
	check(big.player == Vector2i(3, 3), "resize offset")
	var t := big.trimmed()
	check(t.to_rows() == l.to_rows(), "trim restores")


func test_solver_small() -> void:
	var l := lvl([
		"#######",
		"#-----#",
		"#-$-$-#",
		"#-.@.-#",
		"#######",
	])
	var solver := SokobanSolver.new()
	var st := solver.solve(l)
	check(st == SokobanSolver.Status.SOLVED, "solved status (%s)" % solver.status_text())
	var s := SokobanState.new(l)
	check(s.apply_lurd(solver.solution), "solution replays: %s" % solver.solution)
	check(s.is_solved(), "solution solves")
	check(solver.pushes == 2, "pushes = 2 (got %d)" % solver.pushes)
	# 已知最优：玩家需要绕到箱子上方再向下推
	var brute := _bfs_optimal_moves(l)
	check(solver.moves == brute, "move optimal: solver %d vs bfs %d" % [solver.moves, brute])


func test_solver_unsolvable() -> void:
	var l := lvl([
		"######",
		"#@-$.#",
		"#--$.#",
		"######",
	])
	# 两箱贴墙并排推向目标是可解的，换成死锁局面验证无解
	var dead := lvl([
		"#####",
		"#@--#",
		"#-$$#",
		"#..-#",
		"#####",
	])
	var solver := SokobanSolver.new()
	check(solver.solve(l) == SokobanSolver.Status.SOLVED, "side-by-side solvable")
	var st := solver.solve(dead)
	check(st == SokobanSolver.Status.UNSOLVABLE, "deadlocked level unsolvable (%s)" % solver.status_text())


func test_grades() -> void:
	var l := lvl(["######", "#@$-.#", "######"])
	check(l.grade_limits() == Vector2i(-1, -1) and l.petals_for(999) == 3, "no par: always three petals")
	# 默认分档：三瓣 par + max(3, 25%)，两瓣 par + max(8, 60%)
	var expected := {13: Vector2i(16, 21), 15: Vector2i(19, 24), 30: Vector2i(38, 48), 45: Vector2i(56, 72), 71: Vector2i(89, 114)}
	for par in expected:
		l.par_moves = par
		check(l.grade_limits() == expected[par], "default grades for par %d: %s" % [par, l.grade_limits()])
	l.par_moves = 30
	check(l.petals_for(30) == 3 and l.petals_for(38) == 3, "three petals up to the first limit")
	check(l.petals_for(39) == 2 and l.petals_for(48) == 2, "two petals up to the second limit")
	check(l.petals_for(49) == 1, "one petal beyond")
	l.grades = PackedInt32Array([33, 40])
	check(l.grade_limits() == Vector2i(33, 40), "manual grades")
	l.grades = PackedInt32Array([20, 10])
	check(l.grade_limits() == Vector2i(30, 30), "manual grades clamped to par and ordered")


func test_builtin_levels() -> void:
	var dir := DirAccess.open("res://levels")
	if dir == null:
		check(false, "levels dir missing")
		return
	var files := Array(dir.get_files()).filter(func(f): return f.ends_with(".json"))
	files.sort()
	for f in files:
		var l := LevelData.load_file("res://levels/" + f)
		check(l != null, "%s loads" % f)
		if l == null:
			continue
		var v := l.validate()
		check(v.errors.is_empty(), "%s valid: %s" % [f, v.errors])
		var solver := SokobanSolver.new()
		var st := solver.solve(l)
		check(st == SokobanSolver.Status.SOLVED, "%s solvable" % f)
		if l.par_moves > 0:
			check(solver.moves == l.par_moves, "%s par_moves %d == solver %d" % [f, l.par_moves, solver.moves])
		if l.solution != "":
			var s := SokobanState.new(l)
			check(s.apply_lurd(l.solution) and s.is_solved(), "%s stored solution replays" % f)
		print("  %s %-6s moves=%d pushes=%d expanded=%d %dms" % [
			f, l.name, solver.moves, solver.pushes, solver.expanded, solver.elapsed_msec])


## 朴素 BFS（玩家位置 + 箱子集合），只用于小关卡交叉验证求解器的步数最优性。
func _bfs_optimal_moves(l: LevelData) -> int:
	var start := SokobanState.new(l)
	var key0 := start.snapshot_key()
	var seen := {key0: true}
	var frontier: Array = [[l.player, l.boxes.duplicate()]]
	var depth := 0
	while not frontier.is_empty():
		var next: Array = []
		for item in frontier:
			var s := SokobanState.new(l)
			s.player = item[0]
			s.boxes = (item[1] as Array[Vector2i]).duplicate()
			s._rebuild_box_map()
			if s.is_solved():
				return depth
			for d in 4:
				var t := SokobanState.new(l)
				t.player = s.player
				t.boxes = s.boxes.duplicate()
				t._rebuild_box_map()
				if t.move(d).moved:
					var k := t.snapshot_key()
					if not seen.has(k):
						seen[k] = true
						next.append([t.player, t.boxes.duplicate()])
		frontier = next
		depth += 1
	return -1
