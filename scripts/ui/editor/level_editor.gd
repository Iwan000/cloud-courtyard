class_name LevelEditor
extends Control
## 关卡编辑器。
##
## 与游戏共用同一套渲染与程序化建筑：每一笔修改都会立即重建建筑，所见即所得。
## 功能：绘制工具（地板/墙/石箱/印记/旅人/擦除）、拖拽连续绘制、Shift 矩形填充、右键擦除、
## 按笔划撤销/重做、画布尺寸调整、自动围墙、主题与建筑种子、等轴/俯视切换、
## 实时校验、后台求解验证（最优步数）、试玩、保存为自制庭院、XSB 导入导出（剪贴板）。

signal test_play(lvl: LevelData)
signal exit
signal palette_changed

enum Tool { FLOOR, WALL, BOX, TARGET, PLAYER, ERASE }

const TOOL_INFO := [
	[Tool.FLOOR, "地板", "1", "floor"],
	[Tool.WALL, "墙", "2", "wall"],
	[Tool.BOX, "石箱", "3", "box"],
	[Tool.TARGET, "印记", "4", "target"],
	[Tool.PLAYER, "旅人", "5", "cloak"],
	[Tool.ERASE, "擦除", "6", ""],
]
const MIN_SIZE := 4
const MAX_SIZE := LevelData.MAX_SIZE

var world: World
var director: LevelDirector
var lvl: LevelData
var tool := Tool.WALL

var _board: BoardView
var _grid: MeshInstance3D
var _cursor: MeshInstance3D
var _history: Array[LevelData] = []
var _redo: Array[LevelData] = []
var _dirty := false
var _saved_hash := 0

# 笔划
var _stroke_active := false
var _stroke_erase := false
var _stroke_rect := false
var _stroke_start := Vector2i.ZERO
var _stroke_changed := false
var _last_cell := Vector2i(-999, -999)
var _rebuild_pending := false

# 求解
var _solver: SokobanSolver
var _solver_task := -1
var _solved_hash := 0
var _solve_result := {}

# UI
var _tool_buttons: Array[EditorToolButton] = []
var _name_edit: LineEdit
var _status_box: VBoxContainer
var _solve_label: Label
var _solve_button: MvButton
var _replay_button: MvButton
var _size_label: Label
var _toast: Label
var _theme_row: HBoxContainer
var _view_button: MvButton


func open(w: World, d: LevelDirector, source: LevelData) -> void:
	world = w
	director = d
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if source:
		lvl = source.duplicate_level()
		# 给画布四周留出编辑空间
		var pad := Vector2i(2 if lvl.width <= MAX_SIZE - 2 else 0, 2 if lvl.height <= MAX_SIZE - 2 else 0)
		if pad != Vector2i.ZERO:
			lvl = lvl.resized(lvl.width + pad.x, lvl.height + pad.y, Vector2i(pad.x >> 1, pad.y >> 1))
	else:
		lvl = _starter_level()
	_saved_hash = lvl.content_hash() if source else 0
	_build_scene()
	_build_ui()
	_rebuild(true)
	_refresh_status()


func _starter_level() -> LevelData:
	var l := LevelData.from_rows(PackedStringArray([
		"",
		" ########",
		" #------#",
		" #-@-$-.#",
		" #------#",
		" ########",
		"",
	]))
	l = l.resized(10, 8, Vector2i(0, 0))
	l.name = "新的庭院"
	l.name_en = "A New Courtyard"
	l.theme = "dawn"
	l.decor_seed = randi() % 100000
	return l


# ---------------------------------------------------------------------------
# 3D 场景
# ---------------------------------------------------------------------------

func _build_scene() -> void:
	world.canvas_dims = Vector2i(lvl.width, lvl.height)
	world.load_level(lvl, false)
	world.frame_canvas(lvl.width, lvl.height)
	_board = BoardView.new()
	_board.name = "EditorBoard"
	world.add_child(_board)
	_grid = MeshInstance3D.new()
	_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(_grid)
	_cursor = MeshInstance3D.new()
	_cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.albedo_color = Color(1, 1, 1, 0.35)
	cm.no_depth_test = true
	var box := BoxMesh.new()
	box.size = Vector3(0.96, 0.02, 0.96)
	box.material = cm
	_cursor.mesh = box
	_cursor.visible = false
	world.add_child(_cursor)


func _exit_tree() -> void:
	_cancel_solver()
	_release_world()
	for n in [_board, _grid, _cursor]:
		if n and is_instance_valid(n):
			n.queue_free()


func _release_world() -> void:
	if world:
		world.canvas_dims = Vector2i.ZERO
		if world.is_top_down():
			world.set_top_down(false, false)


## 试玩前挂起：隐藏界面与辅助物件，保留全部编辑状态。
func suspend() -> void:
	visible = false
	_stroke_active = false
	for n in [_board, _grid, _cursor]:
		n.visible = false
	_release_world()
	_view_button.text = "俯视视角 (Tab)"


func resume() -> void:
	visible = true
	_board.visible = true
	_grid.visible = true
	_rebuild(true)
	_refresh_status()


func _build_grid_mesh() -> void:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(UiKit.ink, 0.22)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var y := 0.008
	for x in range(lvl.width + 1):
		im.surface_add_vertex(Vector3(x - 0.5, y, -0.5))
		im.surface_add_vertex(Vector3(x - 0.5, y, lvl.height - 0.5))
	for z in range(lvl.height + 1):
		im.surface_add_vertex(Vector3(-0.5, y, z - 0.5))
		im.surface_add_vertex(Vector3(lvl.width - 0.5, y, z - 0.5))
	im.surface_end()
	_grid.mesh = im


## 重建建筑与物件（每笔修改后调用；同一帧内多次修改合并为一次）。
func _rebuild(full := false) -> void:
	if full:
		world.load_level(lvl, false)
		world.frame_canvas(lvl.width, lvl.height)
		world.canvas_dims = Vector2i(lvl.width, lvl.height)
		_build_grid_mesh()
	else:
		world.rebuild_monument(lvl)
	_board.setup(SokobanState.new(lvl), world.mats, world.theme)


func _queue_rebuild() -> void:
	if not _rebuild_pending:
		_rebuild_pending = true
		_do_rebuild.call_deferred()


func _do_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
	_refresh_status()


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	for c in get_children():
		c.queue_free()
	_tool_buttons.clear()
	# 顶部：返回 + 标题 + 名称
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 18)
	add_child(top)
	UiKit.pin(top, 0.0, 0.0, 40, 32)
	var back := UiKit.icon_button("back", "返回 (Esc)")
	back.pressed.connect(_request_exit)
	top.add_child(back)
	var title := UiKit.label("关卡编辑器", 32, 700)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(title)
	var sp := Control.new()
	sp.custom_minimum_size.x = 24
	top.add_child(sp)
	_name_edit = LineEdit.new()
	_name_edit.text = lvl.name
	_name_edit.placeholder_text = "庭院名称"
	_name_edit.custom_minimum_size = Vector2(260, 44)
	_name_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name_edit.add_theme_font_size_override("font_size", 22)
	_name_edit.max_length = 12
	_name_edit.text_changed.connect(func(t: String):
		lvl.name = t if t.strip_edges() != "" else "未命名"
		_dirty = true)
	top.add_child(_name_edit)

	# 左侧：工具
	var tools_panel := _panel()
	add_child(tools_panel)
	UiKit.pin(tools_panel, 0.0, 0.5, 28, -10)
	var tools := VBoxContainer.new()
	tools.add_theme_constant_override("separation", 4)
	tools_panel.add_child(tools)
	tools.add_child(UiKit.label("工具", 17, 600, Color(UiKit.ink, 0.5)))
	for info in TOOL_INFO:
		var b := EditorToolButton.new()
		b.tool_id = info[0]
		b.caption = info[1]
		b.hotkey = info[2]
		if info[3] != "":
			if info[3] == "target":
				b.colors = [Color(world.theme["target"]), Color(world.theme["target"]), Color(world.theme["target"])]
			else:
				b.colors = ThemePalette.tri(world.theme, info[3])
		var tid: int = info[0]
		b.pressed.connect(func(): _set_tool(tid))
		tools.add_child(b)
		_tool_buttons.append(b)
	var hint := UiKit.label("左键绘制 · 右键擦除\nShift + 拖拽：矩形填充", 15, 400, Color(UiKit.ink, 0.5))
	tools.add_child(hint)
	_set_tool(tool)

	# 右侧：主题、校验、求解
	var right_panel := _panel()
	add_child(right_panel)
	UiKit.pin(right_panel, 1.0, 0.0, -28, 28)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.custom_minimum_size.x = 300
	right_panel.add_child(right)
	right.add_child(UiKit.label("主题", 17, 600, Color(UiKit.ink, 0.5)))
	_theme_row = HBoxContainer.new()
	_theme_row.add_theme_constant_override("separation", 10)
	right.add_child(_theme_row)
	for th_id in LevelData.THEMES:
		var sw := ThemeSwatch.new()
		sw.theme_id = th_id
		sw.selected = th_id == lvl.theme
		sw.tooltip_text = ThemePalette.get_theme(th_id)["title"]
		sw.pressed.connect(func(): _set_theme(th_id))
		_theme_row.add_child(sw)
	var reroll := UiKit.text_button("换一种建筑形态", 19)
	reroll.pressed.connect(_reroll)
	right.add_child(reroll)
	_view_button = UiKit.text_button("俯视视角 (Tab)", 19)
	_view_button.pressed.connect(_toggle_view)
	right.add_child(_view_button)
	var sp2 := Control.new()
	sp2.custom_minimum_size.y = 12
	right.add_child(sp2)
	right.add_child(UiKit.label("校验", 17, 600, Color(UiKit.ink, 0.5)))
	_status_box = VBoxContainer.new()
	_status_box.add_theme_constant_override("separation", 2)
	right.add_child(_status_box)
	var sp3 := Control.new()
	sp3.custom_minimum_size.y = 8
	right.add_child(sp3)
	right.add_child(UiKit.label("求解验证", 17, 600, Color(UiKit.ink, 0.5)))
	_solve_label = UiKit.label("尚未求解", 19, 400, Color(UiKit.ink, 0.75))
	_solve_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_solve_label.custom_minimum_size.x = 300
	right.add_child(_solve_label)
	_solve_button = UiKit.text_button("求解最优步数", 21)
	_solve_button.pressed.connect(_start_solve)
	right.add_child(_solve_button)
	_replay_button = UiKit.text_button("演示最优解", 21)
	_replay_button.pressed.connect(_play_solution)
	_replay_button.visible = false
	right.add_child(_replay_button)

	# 底部：画布与文件操作
	var bottom_panel := _panel(14)
	add_child(bottom_panel)
	UiKit.pin(bottom_panel, 0.5, 1.0, 0, -22)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 20)
	bottom_panel.add_child(bottom)
	bottom.add_child(UiKit.label("画布", 17, 600, Color(UiKit.ink, 0.5)))
	_size_label = UiKit.label("", 20, 500)
	_size_label.custom_minimum_size.x = 76
	_size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for spec in [["宽−", Vector2i(-1, 0)], ["宽＋", Vector2i(1, 0)]]:
		bottom.add_child(_small_button(spec[0], _resize.bind(spec[1])))
	bottom.add_child(_size_label)
	for spec in [["高−", Vector2i(0, -1)], ["高＋", Vector2i(0, 1)]]:
		bottom.add_child(_small_button(spec[0], _resize.bind(spec[1])))
	bottom.add_child(_sep())
	bottom.add_child(_small_button("撤销", _undo))
	bottom.add_child(_small_button("重做", _redo_action))
	bottom.add_child(_small_button("自动围墙", _auto_wall))
	bottom.add_child(_small_button("清空", _clear))
	bottom.add_child(_sep())
	bottom.add_child(_small_button("导入 XSB", _import_xsb))
	bottom.add_child(_small_button("导出 XSB", _export_xsb))
	bottom.add_child(_sep())
	bottom.add_child(_small_button("保存", _save, 24))
	bottom.add_child(_small_button("试玩", _test, 24))

	_toast = UiKit.label("", 21, 500)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0
	_toast.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.8))
	_toast.add_theme_constant_override("shadow_outline_size", 10)
	add_child(_toast)
	UiKit.pin(_toast, 0.5, 1.0, 0, -112)
	_update_size_label()


func _panel(vpad := 22) -> PanelContainer:
	var p := PanelContainer.new()
	var st := UiKit.panel_style(0.5, 20)
	st.content_margin_left = 22
	st.content_margin_right = 22
	st.content_margin_top = vpad
	st.content_margin_bottom = vpad
	st.shadow_size = 12
	p.add_theme_stylebox_override("panel", st)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	return p


func _small_button(text: String, cb: Callable, px := 20) -> MvButton:
	var b := UiKit.text_button(text, px)
	b.custom_minimum_size.y = 40
	b.pressed.connect(cb)
	return b


func _sep() -> Control:
	var c := ColorRect.new()
	c.color = Color(UiKit.ink, 0.2)
	c.custom_minimum_size = Vector2(1, 26)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c


func _set_tool(t: int) -> void:
	tool = t as Tool
	for b in _tool_buttons:
		b.selected = b.tool_id == t


func toast(text: String) -> void:
	_toast.text = text
	var tw := _toast.create_tween()
	tw.tween_property(_toast, "modulate:a", 1.0, 0.2)
	tw.tween_interval(2.2)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.6)


func _update_size_label() -> void:
	_size_label.text = "%d × %d" % [lvl.width, lvl.height]


func _refresh_status() -> void:
	for c in _status_box.get_children():
		c.queue_free()
	var v := lvl.validate()
	var stats := UiKit.label("石箱 %d · 印记 %d · 地板 %d" % [lvl.boxes.size(), lvl.target_count(), lvl.floor_count()], 17, 400, Color(UiKit.ink, 0.6))
	_status_box.add_child(stats)
	if v["errors"].is_empty():
		_status_box.add_child(_status_line("✓  可以试玩", Color(UiKit.ink, 0.85)))
	for e in v["errors"]:
		_status_box.add_child(_status_line("·  " + e, Color("c2556a")))
	for wmsg in v["warnings"]:
		_status_box.add_child(_status_line("·  " + wmsg, Color(UiKit.ink, 0.55)))
	# 内容变化后，求解结果作废
	if _solved_hash != lvl.content_hash():
		_solve_result = {}
		_replay_button.visible = false
		if _solver_task < 0:
			_solve_label.text = "尚未求解" if v["errors"].is_empty() else "修正上面的问题后可求解"
		_solve_button.disabled = not v["errors"].is_empty()


func _status_line(text: String, color: Color) -> Label:
	var l := UiKit.label(text, 18, 400, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 300
	return l


# ---------------------------------------------------------------------------
# 输入与绘制
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not visible or world == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if _name_edit.has_focus():
			if event.keycode == KEY_ENTER or event.keycode == KEY_ESCAPE:
				_name_edit.release_focus()
			return
		var k: int = event.keycode
		var ctrl: bool = event.ctrl_pressed or event.meta_pressed
		if ctrl and k == KEY_Z:
			if event.shift_pressed:
				_redo_action()
			else:
				_undo()
		elif ctrl and k == KEY_Y:
			_redo_action()
		elif ctrl and k == KEY_S:
			_save()
		elif k >= KEY_1 and k <= KEY_6:
			_set_tool(k - KEY_1)
			Sfx.play("ui_click")
		elif k == KEY_TAB:
			_toggle_view()
		elif k == KEY_F5 or k == KEY_T:
			_test()
		elif k == KEY_ESCAPE:
			_request_exit()
		else:
			return
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				var cell := _pick(mb.position)
				if not lvl.in_bounds(cell):
					return
				_begin_stroke(cell, mb.button_index == MOUSE_BUTTON_RIGHT, mb.shift_pressed)
			elif _stroke_active:
				_end_stroke(_pick(mb.position))
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var cell := _pick(event.position)
		_update_cursor(cell)
		if _stroke_active and not _stroke_rect and cell != _last_cell and lvl.in_bounds(cell):
			_paint_line(_last_cell, cell)
			_last_cell = cell


## 鼠标拾取：按真实高度依次与墙顶、箱顶、地面相交，取最先命中的格子。
func _pick(screen_pos: Vector2) -> Vector2i:
	var cam := world.camera
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-5:
		return Vector2i(-999, -999)
	for h in [MonumentBuilder.WALL_HIGH, Props.BOX_SIZE, MonumentBuilder.WALL_LOW]:
		var p: Vector3 = from + dir * ((h - from.y) / dir.y)
		var c := Vector2i(roundi(p.x), roundi(p.z))
		if world.builder and world.builder.wall_h.has(c) and is_equal_approx(world.builder.wall_h[c], h):
			return c
		if is_equal_approx(h, Props.BOX_SIZE) and lvl.has_box(c):
			return c
	var p0 := from + dir * (-from.y / dir.y)
	return Vector2i(roundi(p0.x), roundi(p0.z))


func _update_cursor(cell: Vector2i) -> void:
	_cursor.visible = lvl.in_bounds(cell)
	if _cursor.visible:
		var h := 0.0
		if world.builder and world.builder.wall_h.has(cell):
			h = world.builder.wall_h[cell]
		elif lvl.has_box(cell):
			h = Props.BOX_SIZE
		_cursor.position = Vector3(cell.x, h + 0.02, cell.y)


func _begin_stroke(cell: Vector2i, erase: bool, rect: bool) -> void:
	_push_history()
	_stroke_active = true
	_stroke_erase = erase
	_stroke_rect = rect and _tool_supports_rect(erase)
	_stroke_start = cell
	_stroke_changed = false
	_last_cell = cell
	if not _stroke_rect:
		_apply_cell(cell)


func _end_stroke(cell: Vector2i) -> void:
	if _stroke_rect and lvl.in_bounds(cell):
		var a := Vector2i(mini(_stroke_start.x, cell.x), mini(_stroke_start.y, cell.y))
		var b := Vector2i(maxi(_stroke_start.x, cell.x), maxi(_stroke_start.y, cell.y))
		for y in range(a.y, b.y + 1):
			for x in range(a.x, b.x + 1):
				_apply_cell(Vector2i(x, y), true)
		_queue_rebuild()
	_stroke_active = false
	if not _stroke_changed:
		_history.pop_back()   # 本笔划没有改动，不记录
	else:
		_redo.clear()
		_dirty = true


func _tool_supports_rect(erase: bool) -> bool:
	return erase or tool == Tool.FLOOR or tool == Tool.WALL or tool == Tool.ERASE


func _paint_line(a: Vector2i, b: Vector2i) -> void:
	# 拖得很快时补齐中间的格子
	var steps := maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in range(1, steps + 1):
		var t := float(i) / steps
		var c := Vector2i(roundi(lerpf(a.x, b.x, t)), roundi(lerpf(a.y, b.y, t)))
		_apply_cell(c)


## 在一个格子上应用当前工具。返回是否有改动。
func _apply_cell(c: Vector2i, batch := false) -> bool:
	if not lvl.in_bounds(c):
		return false
	var before := _cell_signature(c)
	var t := Tool.ERASE if _stroke_erase else tool
	match t:
		Tool.FLOOR:
			lvl.set_cell(c, LevelData.Cell.FLOOR)
		Tool.WALL:
			lvl.set_cell(c, LevelData.Cell.WALL)
			lvl.boxes.erase(c)
			lvl.set_target(c, false)
			if lvl.player == c:
				lvl.player = Vector2i(-1, -1)
		Tool.BOX:
			if lvl.player == c:
				Sfx.play("bump", 1.0, -6.0)
				return false
			lvl.set_cell(c, LevelData.Cell.FLOOR)
			if lvl.has_box(c):
				if _last_cell == c and _stroke_start == c:
					lvl.boxes.erase(c)   # 单击已有石箱：移除
			else:
				lvl.boxes.append(c)
		Tool.TARGET:
			lvl.set_cell(c, LevelData.Cell.FLOOR)
			if _stroke_start == c and _last_cell == c:
				lvl.set_target(c, not lvl.is_target(c))
			else:
				lvl.set_target(c, true)
		Tool.PLAYER:
			lvl.set_cell(c, LevelData.Cell.FLOOR)
			lvl.boxes.erase(c)
			lvl.player = c
		Tool.ERASE:
			if lvl.has_box(c) or lvl.player == c or lvl.is_target(c):
				lvl.boxes.erase(c)
				lvl.set_target(c, false)
				if lvl.player == c:
					lvl.player = Vector2i(-1, -1)
			else:
				lvl.set_cell(c, LevelData.Cell.VOID)
	var changed := before != _cell_signature(c)
	if changed:
		_stroke_changed = true
		Sfx.play("editor_erase" if t == Tool.ERASE else "editor_place", randf_range(0.92, 1.08))
		if not batch:
			_queue_rebuild()
	return changed


func _cell_signature(c: Vector2i) -> String:
	return "%d%d%d%d" % [lvl.get_cell(c), int(lvl.is_target(c)), int(lvl.has_box(c)), int(lvl.player == c)]


# ---------------------------------------------------------------------------
# 历史
# ---------------------------------------------------------------------------

func _push_history() -> void:
	_history.append(lvl.duplicate_level())
	if _history.size() > 200:
		_history.pop_front()


func _undo() -> void:
	if _history.is_empty():
		toast("没有可以撤销的操作")
		return
	_redo.append(lvl.duplicate_level())
	_restore(_history.pop_back())
	Sfx.play("undo")


func _redo_action() -> void:
	if _redo.is_empty():
		return
	_history.append(lvl.duplicate_level())
	_restore(_redo.pop_back())
	Sfx.play("undo", 1.2)


func _restore(snapshot: LevelData) -> void:
	var size_changed := snapshot.width != lvl.width or snapshot.height != lvl.height
	var theme_switched := snapshot.theme != lvl.theme
	lvl = snapshot.duplicate_level()
	_name_edit.text = lvl.name
	_dirty = true
	_after_structural_change(size_changed or theme_switched)


func _after_structural_change(full: bool) -> void:
	_update_size_label()
	_rebuild(full)
	_refresh_status()
	if full:
		palette_changed.emit()


# ---------------------------------------------------------------------------
# 编辑命令
# ---------------------------------------------------------------------------

func _resize(delta: Vector2i) -> void:
	var nw := clampi(lvl.width + delta.x, MIN_SIZE, MAX_SIZE)
	var nh := clampi(lvl.height + delta.y, MIN_SIZE, MAX_SIZE)
	if nw == lvl.width and nh == lvl.height:
		toast("画布尺寸范围为 %d ~ %d" % [MIN_SIZE, MAX_SIZE])
		return
	_push_history()
	_redo.clear()
	lvl = lvl.resized(nw, nh)
	_dirty = true
	_after_structural_change(true)


## 自动围墙：所有地板格周围的虚空补上墙。
func _auto_wall() -> void:
	_push_history()
	var changed := false
	for y in lvl.height:
		for x in lvl.width:
			var p := Vector2i(x, y)
			if lvl.get_cell(p) != LevelData.Cell.VOID:
				continue
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if lvl.is_floor(p + Vector2i(dx, dy)):
						lvl.set_cell(p, LevelData.Cell.WALL)
						changed = true
	if changed:
		_redo.clear()
		_dirty = true
		Sfx.play("editor_place")
		_queue_rebuild()
		toast("已为地板补全围墙")
	else:
		_history.pop_back()
		toast("地板已被墙完全包围")


func _clear() -> void:
	_push_history()
	_redo.clear()
	var keep := lvl
	lvl = LevelData.create_empty(lvl.width, lvl.height)
	lvl.name = keep.name
	lvl.name_en = keep.name_en
	lvl.theme = keep.theme
	lvl.decor_seed = keep.decor_seed
	lvl.id = keep.id
	_dirty = true
	Sfx.play("editor_erase", 0.8)
	_after_structural_change(false)


func _set_theme(th_id: String) -> void:
	if th_id == lvl.theme:
		return
	_push_history()
	lvl.theme = th_id
	_dirty = true
	for sw in _theme_row.get_children():
		(sw as ThemeSwatch).selected = (sw as ThemeSwatch).theme_id == th_id
	_after_structural_change(true)
	_build_ui()
	_refresh_status()


func _reroll() -> void:
	_push_history()
	lvl.decor_seed = randi() % 1000000
	_dirty = true
	Sfx.play("editor_place", 1.3)
	_rebuild()
	toast("建筑形态已更换（种子 %d）" % lvl.decor_seed)


func _toggle_view() -> void:
	var on := not world.is_top_down()
	world.set_top_down(on)
	_view_button.text = "等轴视角 (Tab)" if on else "俯视视角 (Tab)"
	Sfx.play("ui_click")


func _import_xsb() -> void:
	var text := DisplayServer.clipboard_get()
	if text.strip_edges() == "":
		toast("剪贴板为空：请先复制一段 XSB 地图文本")
		return
	var imported := LevelData.from_xsb(text)
	if imported.width < 1 or imported.width > MAX_SIZE or imported.height > MAX_SIZE:
		toast("无法导入：地图尺寸需在 %d × %d 以内" % [MAX_SIZE, MAX_SIZE])
		return
	_push_history()
	_redo.clear()
	imported.name = lvl.name
	imported.name_en = lvl.name_en
	imported.theme = lvl.theme
	imported.decor_seed = lvl.decor_seed
	imported.id = lvl.id
	var w := clampi(imported.width + 2, MIN_SIZE, MAX_SIZE)
	var h := clampi(imported.height + 2, MIN_SIZE, MAX_SIZE)
	lvl = imported.resized(w, h, Vector2i((w - imported.width) >> 1, (h - imported.height) >> 1))
	_dirty = true
	_after_structural_change(true)
	toast("已从剪贴板导入 XSB 地图")


func _export_xsb() -> void:
	DisplayServer.clipboard_set(lvl.trimmed().to_xsb())
	toast("XSB 地图已复制到剪贴板")


func _save() -> void:
	var out := lvl.trimmed()
	var v := out.validate()
	if not v["errors"].is_empty():
		toast("暂时无法保存：" + v["errors"][0])
		Sfx.play("bump", 1.0, -6.0)
		return
	if not _solve_result.is_empty() and _solved_hash == lvl.content_hash() and _solve_result["status"] == SokobanSolver.Status.SOLVED:
		out.par_moves = _solve_result["moves"]
		out.par_pushes = _solve_result["pushes"]
		out.solution = _solve_result["solution"]
	else:
		out.par_moves = -1
		out.par_pushes = -1
		out.solution = ""
	lvl.id = Game.save_custom_level(out)
	_saved_hash = lvl.content_hash()
	_dirty = false
	Sfx.play("target_on", 1.2, -6.0)
	toast("已保存到“自制庭院”：%s" % out.name + ("" if out.par_moves > 0 else "（建议先求解验证）"))


func _test() -> void:
	var v := lvl.validate()
	if not v["errors"].is_empty():
		toast("暂时无法试玩：" + v["errors"][0])
		Sfx.play("bump", 1.0, -6.0)
		return
	var play := lvl.trimmed()
	if _solved_hash == lvl.content_hash() and not _solve_result.is_empty() and _solve_result["status"] == SokobanSolver.Status.SOLVED:
		play.par_moves = _solve_result["moves"]
		play.solution = _solve_result["solution"]
	test_play.emit(play)


func _request_exit() -> void:
	if _dirty and lvl.content_hash() != _saved_hash:
		if _toast.text != "还有未保存的修改，再按一次返回将放弃":
			toast("还有未保存的修改，再按一次返回将放弃")
			return
	exit.emit()


# ---------------------------------------------------------------------------
# 求解
# ---------------------------------------------------------------------------

func _start_solve() -> void:
	var v := lvl.validate()
	if not v["errors"].is_empty():
		return
	_cancel_solver()
	_solver = SokobanSolver.new()
	_solver.max_msec = 25000
	var snapshot := lvl.duplicate_level()
	_solved_hash = lvl.content_hash()
	_solve_label.text = "求解中……"
	_solve_button.disabled = true
	_solver_task = WorkerThreadPool.add_task(func(): _solver.solve(snapshot), false, "editor_solve")


func _cancel_solver() -> void:
	if _solver:
		_solver.cancelled = true
	if _solver_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_solver_task)
		_solver_task = -1


func _process(_delta: float) -> void:
	if _solver_task >= 0 and WorkerThreadPool.is_task_completed(_solver_task):
		WorkerThreadPool.wait_for_task_completion(_solver_task)
		_solver_task = -1
		_solve_button.disabled = false
		if _solved_hash != lvl.content_hash():
			_refresh_status()
			return
		_solve_result = {
			"status": _solver.status, "moves": _solver.moves, "pushes": _solver.pushes,
			"solution": _solver.solution,
		}
		match _solver.status:
			SokobanSolver.Status.SOLVED:
				_solve_label.text = "可解 ✓  最优 %d 步 · %d 次推动\n（搜索 %d 个局面，用时 %.1f 秒）" % [
					_solver.moves, _solver.pushes, _solver.expanded, _solver.elapsed_msec / 1000.0]
				_replay_button.visible = true
				Sfx.play("target_on", 1.0, -6.0)
			SokobanSolver.Status.UNSOLVABLE:
				_solve_label.text = "无解：任何推法都无法让所有石箱归位"
				Sfx.play("bump")
			SokobanSolver.Status.LIMIT:
				_solve_label.text = "超出搜索上限（局面过于复杂），无法确认是否可解"
			_:
				_solve_label.text = "求解已取消"


func _play_solution() -> void:
	if _solve_result.is_empty():
		return
	var play := lvl.trimmed()
	play.par_moves = _solve_result["moves"]
	play.solution = _solve_result["solution"]
	play.set_meta("autoplay", true)
	test_play.emit(play)


## 主题色块按钮
class ThemeSwatch:
	extends Button
	var theme_id := "dawn"
	var selected := false:
		set(v):
			selected = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(48, 48)
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _draw() -> void:
		var th := ThemePalette.get_theme(theme_id)
		var c := size * 0.5
		var r := 18.0
		draw_circle(c, r + 4, Color(1, 1, 1, 0.6 if selected else 0.0))
		if selected:
			draw_arc(c, r + 4, 0, TAU, 40, Color(UiKit.ink, 0.6), 1.5, true)
		# 上半天空，下半墙色
		var pts_top := PackedVector2Array()
		var pts_bot := PackedVector2Array()
		for i in range(17):
			var a := PI + PI * i / 16.0
			pts_top.append(c + Vector2(cos(a), sin(a)) * r)
			pts_bot.append(c + Vector2(cos(a - PI), sin(a - PI)) * r)
		draw_colored_polygon(pts_top, th["sky_top"])
		draw_colored_polygon(pts_bot, Color(th["wall"][1]))
		draw_circle(c + Vector2(5, -6), 3.5, Color(th["box"][0]))
