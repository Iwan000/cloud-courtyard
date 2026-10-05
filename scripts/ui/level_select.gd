class_name LevelSelect
extends Control
## 选关：左侧章节列表，右侧是所选庭院的实景预览（真实建筑在云海中升起）。

signal selection_changed(lvl: LevelData)
signal play_level(lvl: LevelData)
signal edit_level(lvl: LevelData)
signal new_level
signal back

var _entries: Array = []      # [{lvl, button, locked}]
var _selected := 0
var _detail: VBoxContainer
var _play_button: MvButton
var _edit_button: MvButton


func build(select_id := "") -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	add_child(col)
	UiKit.pin(col, 0.0, 0.5, 120, 0)

	var back_btn := UiKit.icon_button("back", "返回")
	back_btn.pressed.connect(func(): back.emit())
	add_child(back_btn)
	UiKit.pin(back_btn, 0.0, 0.0, 48, 40)

	var head := UiKit.label("选择庭院", 44, 700)
	col.add_child(head)
	var sp := Control.new()
	sp.custom_minimum_size.y = 30
	col.add_child(sp)

	for i in Game.builtin.size():
		var lvl: LevelData = Game.builtin[i]
		var locked := not Game.is_unlocked(i)
		_add_entry(col, lvl, UiKit.roman(i + 1), locked)

	if not Game.custom.is_empty():
		var sp2 := Control.new()
		sp2.custom_minimum_size.y = 18
		col.add_child(sp2)
		col.add_child(UiKit.label("自制庭院", 18, 600, Color(UiKit.ink, 0.55)))
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(520, mini(Game.custom.size(), 3) * 54)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 2)
		scroll.add_child(inner)
		col.add_child(scroll)
		for lvl in Game.custom:
			_add_entry(inner, lvl, "◇", false, true)

	var sp3 := Control.new()
	sp3.custom_minimum_size.y = 14
	col.add_child(sp3)
	var new_btn := UiKit.text_button("＋ 新建庭院", 20)
	new_btn.pressed.connect(func(): new_level.emit())
	col.add_child(new_btn)

	# 右下：详情与开始
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 4)
	_detail.alignment = BoxContainer.ALIGNMENT_END
	add_child(_detail)
	UiKit.pin(_detail, 1.0, 1.0, -96, -72)

	var start := 0
	for i in _entries.size():
		if _entries[i]["lvl"].id == select_id:
			start = i
	for i in _entries.size():
		UiKit.appear(_entries[i]["button"], 0.05 * i)
	_select(start)


func _add_entry(parent: Control, lvl: LevelData, numeral: String, locked: bool, is_custom := false) -> void:
	var b := MvButton.new()
	var px := 30 if not is_custom else 24
	b.setup("· · ·" if locked else lvl.name, px)
	# 序号单独成列（按所有序号的最大宽度对齐），名字统一左对齐
	b.set_prefix(numeral, _numeral_column_width(px))
	b.custom_minimum_size.x = 210 if not is_custom else 240
	if locked:
		b.self_modulate.a = 0.45   # 用 self_modulate，避免被入场淡入动画覆盖
	var idx := _entries.size()
	b.pressed.connect(func():
		if _selected == idx:
			_activate()
		else:
			_select(idx))
	b.focus_entered.connect(func():
		if _selected != idx:
			_select(idx))
	parent.add_child(b)
	_entries.append({"lvl": lvl, "button": b, "locked": locked, "custom": is_custom})


## 序号列宽：所有内置关卡罗马数字中最宽者 + 间距。
func _numeral_column_width(px: int) -> float:
	var font := UiKit.font(500)
	var w := 0.0
	for i in Game.builtin.size():
		w = maxf(w, font.get_string_size(UiKit.roman(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, px).x)
	w = maxf(w, font.get_string_size("◇", HORIZONTAL_ALIGNMENT_LEFT, -1, px).x)
	return w + px * 0.8


func _select(i: int) -> void:
	_selected = clampi(i, 0, _entries.size() - 1)
	var e: Dictionary = _entries[_selected]
	var b: MvButton = e["button"]
	if not b.has_focus():
		b.grab_focus()
	_rebuild_detail()
	selection_changed.emit(e["lvl"])


func _rebuild_detail() -> void:
	for c in _detail.get_children():
		c.queue_free()
	var e: Dictionary = _entries[_selected]
	var lvl: LevelData = e["lvl"]
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 34)
	if e["custom"]:
		_edit_button = UiKit.text_button("编辑", 24)
		_edit_button.pressed.connect(func(): edit_level.emit(lvl))
		row.add_child(_edit_button)
	_play_button = UiKit.text_button("进入庭院" if not e["locked"] else "尚未解锁", 34)
	_play_button.disabled = e["locked"]
	_play_button.focus_mode = Control.FOCUS_NONE
	_play_button.pressed.connect(_activate)
	row.add_child(_play_button)
	_detail.add_child(row)
	UiKit.appear(row, 0.05)


func _activate() -> void:
	var e: Dictionary = _entries[_selected]
	if e["locked"]:
		Sfx.play("bump", 1.0, -6.0)
		return
	play_level.emit(e["lvl"])


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		back.emit()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_activate()
		get_viewport().set_input_as_handled()
