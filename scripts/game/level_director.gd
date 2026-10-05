class_name LevelDirector
extends Node
## 关卡演出导演：入场（建筑从云海升起）、退场（沉入云海）、通关"机关苏醒"。

var world: World
var board: BoardView
var _build_tween: Tween
var _cam_tween: Tween


func setup(w: World, b: BoardView) -> void:
	world = w
	board = b


func _kill() -> void:
	if _build_tween and _build_tween.is_valid():
		_build_tween.kill()


## 入场演出。with_board=false 时只升起建筑（选关预览）。
func play_intro(with_board := true) -> void:
	_kill()
	if with_board:
		board.visible = false
	Sfx.play("intro")
	world.set_build(0.0)
	_build_tween = create_tween()
	_build_tween.tween_method(world.set_build, 0.0, 1.0, 2.0)
	await _build_tween.finished
	var wt := create_tween()
	wt.tween_method(world.set_water_flow, 0.0, 1.0, 1.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	for i in world.builder.tree_nodes.size():
		var tr := world.builder.tree_nodes[i]
		var tt := tr.create_tween()
		tt.tween_interval(i * 0.15)
		tt.tween_property(tr, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if with_board:
		await board.play_intro()


## 退场演出：物件消失，建筑由外向内沉入云海。
func play_outro(with_board := true) -> void:
	_kill()
	if with_board and board.visible:
		board.play_outro()
	world.set_water_flow(0.0)
	_build_tween = create_tween()
	_build_tween.tween_method(world.set_build, 1.0, 0.0, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await _build_tween.finished


## 通关演出"机关苏醒"：目标依次闪亮 → 窗户点亮 → 樱花绽放 → 旅人欢呼 → 镜头拉远。
func play_complete() -> void:
	var targets := board.ordered_targets()
	for i in targets.size():
		board.flash_target(targets[i])
		Sfx.play_bell(4 + i, -3.0)
		await get_tree().create_timer(0.2).timeout
	Sfx.play("win")
	board.cheer()
	var lt := create_tween()
	lt.tween_method(world.set_windows_lit, 0.0, 1.0, 1.4).set_trans(Tween.TRANS_SINE)
	for tr in world.builder.tree_nodes:
		var tt := tr.create_tween()
		tt.tween_property(tr, "scale", Vector3.ONE * 1.2, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tt.tween_property(tr, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_SINE)
		board.fx.petals(tr.global_position + Vector3(0, 0.5, 0), Color(world.theme["foliage"][0]), 24)
	for w in world.builder.water_nodes:
		board.fx.sparkles(w.global_position + Vector3(0, 0.1, 0), Color(world.theme["water"]).lerp(Color.WHITE, 0.6), 8, 0.3, 0.8)
	if _cam_tween and _cam_tween.is_valid():
		_cam_tween.kill()
	_cam_tween = create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_cam_tween.tween_property(world, "cam_size", world.framed_size * 1.14, 3.6)
	# 建筑上移，为下方的结算文字让出空间
	_cam_tween.tween_property(world, "cam_target", world.framed_target - world.camera.basis.y * world.framed_size * 0.13, 3.6)
	await get_tree().create_timer(1.8).timeout


## 镜头回到标准取景。
func reset_camera(duration := 0.8) -> void:
	if _cam_tween and _cam_tween.is_valid():
		_cam_tween.kill()
	_cam_tween = create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_cam_tween.tween_property(world, "cam_size", world.framed_size, duration)
	_cam_tween.tween_property(world, "cam_target", world.framed_target, duration)
	world.set_windows_lit(0.0)
