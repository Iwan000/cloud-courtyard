class_name BoardView
extends Node3D
## 动态物件的表现层：目标地砖、箱子、角色，以及每一步的动画与反馈。
## 只根据 SokobanState / MoveResult 驱动，自身不改动逻辑状态。

signal step_finished(result: SokobanState.MoveResult)

const WALK_TIME := 0.16
const PUSH_TIME := 0.23
const UNDO_TIME := 0.13
const BUMP_TIME := 0.2

var state: SokobanState
var mats: ThemePalette.MaterialLib
var theme: Dictionary
var fx: Fx
var character: Character
var box_nodes: Array[Node3D] = []
var target_nodes := {}   # Vector2i -> MeshInstance3D

## 速度倍率（回放最优解时加速）
var speed := 1.0

var _anim := {}
var _target_glow := {}   # Vector2i -> 当前发光值
var _box_glow: Array[float] = []
var _target_yaw := PI
var _push_hold := 0.0
var _cursor: MeshInstance3D
var _dots: Array[MeshInstance3D] = []
var _dot_mat: StandardMaterial3D


static func cell_pos(p: Vector2i, y := 0.0) -> Vector3:
	return Vector3(p.x, y, p.y)


func setup(st: SokobanState, material_lib: ThemePalette.MaterialLib, theme_dict: Dictionary) -> void:
	state = st
	mats = material_lib
	theme = theme_dict
	for c in get_children():
		c.queue_free()
	box_nodes.clear()
	target_nodes.clear()
	_target_glow.clear()
	_box_glow.clear()
	_anim = {}
	_dots.clear()
	fx = Fx.new()
	fx.name = "Fx"
	add_child(fx)
	# 常驻的漂浮光尘（星夜里像萤火虫）
	var lv := st.level
	var center := Vector3((lv.width - 1) * 0.5, 0.0, (lv.height - 1) * 0.5)
	var night := Color(theme_dict["sky_top"]).get_luminance() < 0.3
	var mote_col := Color(theme_dict["target_glow"]) if night else Color(1, 1, 1)
	fx.ambient_motes(center, Vector2(lv.width * 0.5, lv.height * 0.5), mote_col, 26 if night else 16)
	var target_mesh := Props.make_target_mesh(mats)
	for t in st.level.target_list():
		var mi := MeshInstance3D.new()
		mi.mesh = target_mesh
		mi.position = cell_pos(t, 0.004)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		target_nodes[t] = mi
		_target_glow[t] = 0.0
	var box_mesh := Props.make_box_mesh(mats)
	for i in st.boxes.size():
		var holder := Node3D.new()
		holder.name = "Box%d" % i
		var mi := MeshInstance3D.new()
		mi.mesh = box_mesh
		holder.add_child(mi)
		holder.position = cell_pos(st.boxes[i])
		add_child(holder)
		box_nodes.append(holder)
		_box_glow.append(0.0)
	character = Character.new()
	character.name = "Traveler"
	add_child(character)
	character.build(mats)
	character.position = cell_pos(st.player)
	character.visible = st.level.is_floor(st.player)
	_target_yaw = Character.yaw_for_dir(Vector2i(0, 1))
	character.rotation.y = _target_yaw
	_build_cursor()
	sync_instant()


## 立即把所有节点摆到逻辑状态对应的位置（用于重开、撤销到底等）。
func sync_instant() -> void:
	_anim = {}
	for i in box_nodes.size():
		box_nodes[i].position = cell_pos(state.boxes[i])
		box_nodes[i].scale = Vector3.ONE
	character.position = cell_pos(state.player)
	for t in target_nodes:
		_target_glow[t] = 1.0 if state.box_at(t) >= 0 else 0.0
	for i in box_nodes.size():
		_box_glow[i] = 1.0 if state.level.is_target(state.boxes[i]) else 0.0
	_apply_glow()


func is_busy() -> bool:
	return not _anim.is_empty()


# ---------------------------------------------------------------------------
# 播放一步
# ---------------------------------------------------------------------------

func play(r: SokobanState.MoveResult) -> void:
	clear_hint()
	var kind := "bump"
	var dur := BUMP_TIME
	if r.moved:
		if r.is_undo:
			kind = "undo"
			dur = UNDO_TIME
		elif r.box_id >= 0:
			kind = "push"
			dur = PUSH_TIME
		else:
			kind = "walk"
			dur = WALK_TIME
	_anim = {"kind": kind, "t": 0.0, "dur": dur / speed, "r": r, "fx_done": false}
	if r.dir >= 0:
		_target_yaw = Character.yaw_for_dir(SokobanState.DIRS[r.dir])
	match kind:
		"walk":
			Sfx.play("step", randf_range(0.9, 1.15))
		"push":
			_push_hold = 0.3
			Sfx.play("push", randf_range(0.92, 1.05))
			Sfx.play_push_note()
		"undo":
			Sfx.play("undo")
		"bump":
			Sfx.play("bump", randf_range(0.95, 1.05))


func _dir3(dir: int) -> Vector3:
	if dir < 0:
		return Vector3.ZERO
	var d: Vector2i = SokobanState.DIRS[dir]
	return Vector3(d.x, 0, d.y)


func _process(delta: float) -> void:
	if character == null:
		return
	# 朝向平滑转身
	character.rotation.y = lerp_angle(character.rotation.y, _target_yaw, 1.0 - exp(-delta * 22.0))
	var moving := false
	if not _anim.is_empty():
		moving = _anim["kind"] != "bump"
		_advance(delta)
	character.walk_amount = move_toward(character.walk_amount, 1.0 if moving else 0.0, delta * 8.0)
	if moving:
		character.walk_phase += delta * PI / (WALK_TIME / speed)
	_push_hold = maxf(_push_hold - delta, 0.0)
	character.push_amount = move_toward(character.push_amount, 1.0 if _push_hold > 0.0 else 0.0, delta * 7.0)
	_animate_glow(delta)


func _advance(delta: float) -> void:
	_anim["t"] += delta / _anim["dur"]
	var t: float = minf(_anim["t"], 1.0)
	var r: SokobanState.MoveResult = _anim["r"]
	var kind: String = _anim["kind"]
	var from := cell_pos(r.from)
	var to := cell_pos(r.to)
	match kind:
		"walk":
			var e := _ease_walk(t)
			character.position = from.lerp(to, e) + Vector3(0, sin(PI * t) * 0.05, 0)
			if t >= 0.5 and not _anim["fx_done"]:
				_anim["fx_done"] = true
				fx.footstep(to, Color(theme["fog"]).lerp(Color.WHITE, 0.3))
		"push":
			var e := _ease_push(t)
			character.position = from.lerp(to, e)
			var box := box_nodes[r.box_id]
			box.position = cell_pos(r.box_from).lerp(cell_pos(r.box_to), e)
			if t >= 0.35 and not _anim["fx_done"]:
				_anim["fx_done"] = true
				var dir3 := _dir3(r.dir)
				fx.dust(cell_pos(r.box_from) + dir3 * 0.45, dir3, Color(theme["fog"]).lerp(Color(theme["floor"][1]), 0.5))
		"undo":
			var e := _ease_walk(t)
			character.position = from.lerp(to, e)
			if r.box_id >= 0:
				box_nodes[r.box_id].position = cell_pos(r.box_from).lerp(cell_pos(r.box_to), e)
		"bump":
			var dir3 := _dir3(r.dir)
			var out := sin(PI * minf(t * 1.6, 1.0)) * (1.0 - t * 0.3)
			character.position = from + dir3 * 0.12 * out
			if r.blocked == "box" and r.box_id >= 0:
				var shake := sin(t * PI * 5.0) * (1.0 - t) * 0.03
				box_nodes[r.box_id].position = cell_pos(r.box_from) + dir3 * shake
	if _anim["t"] >= 1.0:
		_finish(r, kind)


func _finish(r: SokobanState.MoveResult, kind: String) -> void:
	_anim = {}
	if kind == "bump":
		character.position = cell_pos(r.from)
		if r.box_id >= 0:
			box_nodes[r.box_id].position = cell_pos(r.box_from)
	else:
		character.position = cell_pos(r.to)
		if r.box_id >= 0:
			var box := box_nodes[r.box_id]
			box.position = cell_pos(r.box_to)
			if kind == "push":
				_settle(box)
	if r.moved and r.box_id >= 0:
		var t_glow := Color(theme["target_glow"])
		if r.box_entered_target:
			var at := cell_pos(r.box_to)
			fx.light_pillar(at, t_glow)
			fx.sparkles(at + Vector3(0, 0.2, 0), t_glow)
			Sfx.play("target_on")
		elif r.box_left_target:
			Sfx.play("target_off", 1.0, -4.0)
	step_finished.emit(r)


func _settle(box: Node3D) -> void:
	var tw := box.create_tween()
	tw.tween_property(box, "scale", Vector3(1.035, 0.95, 1.035), 0.06).set_ease(Tween.EASE_OUT)
	tw.tween_property(box, "scale", Vector3.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static func _ease_walk(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


static func _ease_push(t: float) -> float:
	# 起步稍慢（蓄力），中段加速，末端柔和停住
	return 1.0 - pow(1.0 - pow(t, 1.35), 2.2)


# ---------------------------------------------------------------------------
# 发光
# ---------------------------------------------------------------------------

func _animate_glow(delta: float) -> void:
	var changed := false
	for t in target_nodes:
		var goal := 1.0 if _target_lit(t) else 0.0
		var cur: float = _target_glow[t]
		if not is_equal_approx(cur, goal):
			_target_glow[t] = move_toward(cur, goal, delta * 3.0)
			changed = true
	for i in box_nodes.size():
		var goal := 1.0 if _box_lit(i) else 0.0
		if not is_equal_approx(_box_glow[i], goal):
			_box_glow[i] = move_toward(_box_glow[i], goal, delta * 3.0)
			changed = true
	if changed:
		_apply_glow()


## 动画中的箱子不发光，结束后才点亮目标
func _target_lit(t: Vector2i) -> bool:
	var id := state.box_at(t)
	return id >= 0 and not (_anim.has("r") and (_anim["r"] as SokobanState.MoveResult).box_id == id)


func _box_lit(i: int) -> bool:
	return state.level.is_target(state.boxes[i]) and not (_anim.has("r") and (_anim["r"] as SokobanState.MoveResult).box_id == i)


func _apply_glow() -> void:
	for t in target_nodes:
		(target_nodes[t] as MeshInstance3D).set_instance_shader_parameter("glow", _target_glow[t])
	for i in box_nodes.size():
		var mi := box_nodes[i].get_child(0) as MeshInstance3D
		mi.set_instance_shader_parameter("glow", _box_glow[i])


# ---------------------------------------------------------------------------
# 悬停光标与路径预览
# ---------------------------------------------------------------------------

func _build_cursor() -> void:
	_dot_mat = StandardMaterial3D.new()
	_dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dot_mat.albedo_color = Color(1, 1, 1, 0.55)
	_dot_mat.no_depth_test = false
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	const W := 0.035
	const H := 0.46
	for side in [[Vector3(-H, 0, -H), Vector3(H, 0.003, -H + W)], [Vector3(-H, 0, H - W), Vector3(H, 0.003, H)],
			[Vector3(-H, 0, -H), Vector3(-H + W, 0.003, H)], [Vector3(H - W, 0, -H), Vector3(H, 0.003, H)]]:
		k.box(side[0], side[1], MeshKit.FACE_PY)
	var mesh := ArrayMesh.new()
	k.commit_to(mesh, _dot_mat)
	_cursor = MeshInstance3D.new()
	_cursor.mesh = mesh
	_cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cursor.visible = false
	add_child(_cursor)


func show_cursor(cell: Vector2i, path: Array[int]) -> void:
	_cursor.visible = true
	_cursor.position = cell_pos(cell, 0.012)
	var pts: Array[Vector3] = []
	var p := state.player
	for d in path:
		var q: Vector2i = p + SokobanState.DIRS[d]
		pts.append((cell_pos(p) + cell_pos(q)) * 0.5)
		if q != cell:
			pts.append(cell_pos(q))
		p = q
	while _dots.size() < pts.size():
		var dot := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.045
		cyl.bottom_radius = 0.045
		cyl.height = 0.004
		cyl.radial_segments = 12
		cyl.rings = 1
		dot.mesh = cyl
		dot.material_override = _dot_mat
		dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(dot)
		_dots.append(dot)
	for i in _dots.size():
		_dots[i].visible = i < pts.size()
		if i < pts.size():
			_dots[i].position = pts[i] + Vector3(0, 0.012, 0)


func hide_cursor() -> void:
	if _cursor:
		_cursor.visible = false
	for d in _dots:
		d.visible = false


# ---------------------------------------------------------------------------
# 入场 / 退场 / 欢呼
# ---------------------------------------------------------------------------

## 入场：目标地砖依次浮现，箱子从空中落下，旅人在光点中现身。
func play_intro() -> void:
	visible = true
	for t in target_nodes:
		(target_nodes[t] as Node3D).scale = Vector3.ONE * 0.001
	for b in box_nodes:
		b.visible = false
	character.visible = false
	var order := target_nodes.keys()
	order.sort_custom(func(a, b): return a.x + a.y < b.x + b.y)
	var tw := create_tween().set_parallel()
	for i in order.size():
		var node: Node3D = target_nodes[order[i]]
		tw.tween_property(node, "scale", Vector3.ONE, 0.45).set_delay(i * 0.09).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(0.25).timeout
	for i in box_nodes.size():
		var box := box_nodes[i]
		var final := cell_pos(state.boxes[i])
		box.position = final + Vector3(0, 4.5, 0)
		box.visible = true
		var bt := box.create_tween()
		bt.tween_interval(i * 0.13)
		bt.tween_property(box, "position", final, 0.42).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		bt.tween_callback(func():
			_settle(box)
			fx.dust(final + Vector3(0, 0, 0.0), Vector3(0, 0, 1), Color(theme["fog"]).lerp(Color(theme["floor"][1]), 0.5), 5)
			fx.dust(final, Vector3(0, 0, -1), Color(theme["fog"]).lerp(Color(theme["floor"][1]), 0.5), 5)
			Sfx.play("bump", randf_range(0.85, 1.0), -4.0))
	await get_tree().create_timer(0.42 + box_nodes.size() * 0.13 + 0.15).timeout
	character.visible = true
	character.scale = Vector3.ONE * 0.001
	var at := cell_pos(state.player)
	fx.sparkles(at, Color(theme["target_glow"]), 18, 0.35, 1.0)
	Sfx.play_bell(5, -6.0)
	var ct := character.create_tween()
	ct.tween_property(character, "scale", Vector3.ONE, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await ct.finished
	sync_instant()


## 退场：箱子与旅人缩小消失。
func play_outro() -> void:
	hide_cursor()
	var tw := create_tween().set_parallel()
	for b in box_nodes:
		tw.tween_property(b, "scale", Vector3.ONE * 0.001, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	if character:
		tw.tween_property(character, "scale", Vector3.ONE * 0.001, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	for t in target_nodes:
		tw.tween_property(target_nodes[t], "scale", Vector3.ONE * 0.001, 0.3)
	await tw.finished
	visible = false


## 重开：箱子与旅人收起后回到起点。
func play_reset() -> void:
	hide_cursor()
	_anim = {}
	var tw := create_tween().set_parallel()
	for b in box_nodes:
		tw.tween_property(b, "scale", Vector3.ONE * 0.001, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_property(character, "scale", Vector3.ONE * 0.001, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	await tw.finished
	sync_instant()
	_target_yaw = Character.yaw_for_dir(Vector2i(0, 1))
	character.rotation.y = _target_yaw
	var tw2 := create_tween().set_parallel()
	for i in box_nodes.size():
		tw2.tween_property(box_nodes[i], "scale", Vector3.ONE, 0.35).set_delay(i * 0.05).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw2.tween_property(character, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await tw2.finished


## 通关时目标依次闪亮（返回按顺序排列的目标格）。
func ordered_targets() -> Array:
	var order := target_nodes.keys()
	var p := state.player
	order.sort_custom(func(a, b): return Vector2(a - p).length() < Vector2(b - p).length())
	return order


func flash_target(t: Vector2i) -> void:
	var at := cell_pos(t)
	fx.light_pillar(at, Color(theme["target_glow"]), 3.4)
	fx.sparkles(at + Vector3(0, 0.6, 0), Color(theme["target_glow"]), 10, 0.4, 1.8)
	var id := state.box_at(t)
	if id >= 0:
		var box := box_nodes[id]
		var tw := box.create_tween()
		tw.tween_property(box, "position:y", 0.18, 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(box, "position:y", 0.0, 0.35).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


func cheer() -> void:
	var tw := character.create_tween()
	tw.tween_property(character, "cheer", 1.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(character, "position:y", 0.28, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(character, "position:y", 0.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_interval(0.9)
	tw.tween_property(character, "cheer", 0.0, 0.5)



# ---------------------------------------------------------------------------
# 提示
# ---------------------------------------------------------------------------

var _hint_arrow: Node3D
var _hint_box := -1


## 显示提示：行走路径（虚线点）+ 石箱上方指示推动方向的浮动箭头 + 石箱脉动发光。
func show_hint(box_id: int, push_dir: int, walk: Array[int]) -> void:
	clear_hint()
	var stand := state.boxes[box_id] - SokobanState.DIRS[push_dir]
	if not walk.is_empty():
		show_cursor(stand, walk)
		_cursor.visible = true
	_hint_box = box_id
	_hint_arrow = Node3D.new()
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	# 平放的人字形箭头（指向 +Z），由两段扁长方体组成
	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	arrow_mat.albedo_color = Color(1, 1, 1, 0.92)
	arrow_mat.no_depth_test = true
	arrow_mat.render_priority = 2
	for side in [-1.0, 1.0]:
		var a := Vector3(side * 0.3, 0, -0.12)
		var b := Vector3(0, 0, 0.2)
		var mid := (a + b) * 0.5
		var seg := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.11, 0.05, (b - a).length() + 0.08)
		bm.material = arrow_mat
		seg.mesh = bm
		seg.position = mid
		seg.rotation.y = atan2(b.x - a.x, b.z - a.z)
		_hint_arrow.add_child(seg)
	var d: Vector2i = SokobanState.DIRS[push_dir]
	_hint_arrow.rotation.y = atan2(float(d.x), float(d.y))
	var base := cell_pos(state.boxes[box_id], Props.BOX_SIZE + 0.55)
	_hint_arrow.position = base
	add_child(_hint_arrow)
	var tw := _hint_arrow.create_tween().set_loops(6)
	var dir3 := Vector3(d.x, 0, d.y)
	tw.tween_property(_hint_arrow, "position", base + dir3 * 0.18, 0.45).set_trans(Tween.TRANS_SINE)
	tw.tween_property(_hint_arrow, "position", base, 0.45).set_trans(Tween.TRANS_SINE)
	tw.finished.connect(clear_hint)
	var bt := create_tween().set_loops(3)
	var mi := box_nodes[box_id].get_child(0) as MeshInstance3D
	bt.tween_method(func(v: float): mi.set_instance_shader_parameter("glow", v), 0.0, 0.9, 0.45)
	bt.tween_method(func(v: float): mi.set_instance_shader_parameter("glow", v), 0.9, _box_glow[box_id], 0.45)


func clear_hint() -> void:
	if _hint_arrow and is_instance_valid(_hint_arrow):
		_hint_arrow.queue_free()
	_hint_arrow = null
	if _hint_box >= 0 and _hint_box < box_nodes.size():
		(box_nodes[_hint_box].get_child(0) as MeshInstance3D).set_instance_shader_parameter("glow", _box_glow[_hint_box])
	_hint_box = -1
