class_name Hud
extends Control
## 关卡内 HUD：左上关卡名，右上步数，右下操作按钮，左下操作提示。极简、不抢画面。

signal undo_pressed
signal restart_pressed
signal menu_pressed
signal hint_pressed

var _moves: Label
var _pushes: Label
var _par: Label
var _objective: Label
var _controls: Label
var _title_box: VBoxContainer


func build(lvl: LevelData, index_text: String) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_title_box = VBoxContainer.new()
	_title_box.add_theme_constant_override("separation", 0)
	add_child(_title_box)
	UiKit.pin(_title_box, 0.0, 0.0, 56, 40)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	if index_text != "":
		row.add_child(UiKit.label(index_text, 34, 500, Color(UiKit.ink, 0.6), true))
	row.add_child(UiKit.label(lvl.name, 32, 600))
	_title_box.add_child(row)
	var th := ThemePalette.get_theme(lvl.theme)
	_title_box.add_child(UiKit.label(lvl.name_en if lvl.name_en != "" else th["title_en"], 21, 400, Color(UiKit.ink, 0.62), true, true))

	var stats := VBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_END
	add_child(stats)
	UiKit.pin(stats, 1.0, 0.0, -60, 40)
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_END
	line.add_theme_constant_override("separation", 26)
	_moves = _stat(line, "步数")
	_pushes = _stat(line, "推动")
	stats.add_child(line)
	_par = UiKit.label("", 16, 400, Color(UiKit.ink, 0.5))
	_par.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if lvl.par_moves > 0:
		_par.text = "参考最优 %d 步" % lvl.par_moves
	stats.add_child(_par)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	add_child(buttons)
	UiKit.pin(buttons, 1.0, 1.0, -48, -40)
	for spec in [["hint", "提示 (H)", hint_pressed], ["undo", "撤销 (Z)", undo_pressed], ["restart", "重来 (R)", restart_pressed], ["menu", "菜单 (Esc)", menu_pressed]]:
		var b := UiKit.icon_button(spec[0], spec[1])
		var sig: Signal = spec[2]
		b.pressed.connect(func(): sig.emit())
		buttons.add_child(b)

	_controls = UiKit.label("方向键 / WASD 移动   ·   点击地面自动行走   ·   Z 撤销   ·   R 重来", 16, 400, Color(UiKit.ink, 0.55))
	add_child(_controls)
	UiKit.pin(_controls, 0.0, 1.0, 56, -52)

	_objective = UiKit.glow(UiKit.label("", 22, 500, UiKit.ink), 0.6, 14)
	_objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_objective.modulate.a = 0.0
	add_child(_objective)
	UiKit.pin(_objective, 0.5, 0.0, 0, 120)

	for c in [_title_box, stats, buttons, _controls]:
		UiKit.appear(c, 0.1)
	set_counters(0, 0)


func _stat(parent: Control, caption: String) -> Label:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var cap := UiKit.label(caption, 17, 400, Color(UiKit.ink, 0.55))
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(cap)
	var v := UiKit.label("0", 38, 500, UiKit.ink, true)
	v.custom_minimum_size.x = 44
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(v)
	parent.add_child(box)
	return v


func set_counters(moves: int, pushes: int) -> void:
	_moves.text = str(moves)
	_pushes.text = str(pushes)
	if moves > 0 and _controls.modulate.a > 0.99:
		_controls.create_tween().tween_property(_controls, "modulate:a", 0.0, 1.2).set_delay(2.0)


## 关卡开始时的目标提示，几秒后淡出。
func show_objective(text: String, hold := 3.2) -> void:
	_objective.text = text
	var tw := _objective.create_tween()
	tw.tween_property(_objective, "modulate:a", 1.0, 0.6)
	tw.tween_interval(hold)
	tw.tween_property(_objective, "modulate:a", 0.0, 0.9)


func fade_out(dur := 0.4) -> void:
	create_tween().tween_property(self, "modulate:a", 0.0, dur)
