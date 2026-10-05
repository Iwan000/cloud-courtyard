class_name TitleScreen
extends Control
## 标题界面：游戏名 + 菜单。背景是缓缓升起的浮空庭院。

signal start_pressed
signal select_pressed
signal editor_pressed
signal settings_pressed
signal quit_pressed

var _first_button: Control


func build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	UiKit.pin(box, 0.0, 0.47, 132, 0)
	var kicker := UiKit.label("K U R O   ·   P U S H B O X", 17, 500, Color(UiKit.ink, 0.55), true)
	box.add_child(kicker)
	var title := UiKit.label("云上庭", 104, 600)
	box.add_child(title)
	var sub := UiKit.label("Courtyards in the Clouds", 36, 400, Color(UiKit.ink, 0.8), true, true)
	box.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size.y = 18
	box.add_child(gap)
	box.add_child(UiKit.hline(220, 0.3))
	var gap2 := Control.new()
	gap2.custom_minimum_size.y = 22
	box.add_child(gap2)

	var next := Game.next_level_index()
	var started := false
	for l in Game.builtin:
		if Game.is_completed(l.id):
			started = true
	var start_text := "开始旅程"
	var start_sub := ""
	if started and next < Game.builtin.size():
		start_text = "继续旅程"
		start_sub = "%s · %s" % [UiKit.roman(next + 1), Game.builtin[next].name]
	var items := [
		[start_text, start_sub, start_pressed],
		["选择庭院", "", select_pressed],
		["庭院工坊", "关卡编辑器", editor_pressed],
		["设置", "", settings_pressed],
		["离开", "", quit_pressed],
	]
	var delay := 0.35
	for it in items:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		var b := UiKit.text_button(it[0], 28)
		var sig: Signal = it[2]
		b.pressed.connect(func(): sig.emit())
		row.add_child(b)
		if it[1] != "":
			var s := UiKit.label(it[1], 18, 400, Color(UiKit.ink, 0.5))
			s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(s)
		box.add_child(row)
		UiKit.appear(row, delay)
		delay += 0.07
		if _first_button == null:
			_first_button = b
	UiKit.appear(kicker, 0.0)
	UiKit.appear(title, 0.08)
	UiKit.appear(sub, 0.18)

	var foot := UiKit.label("方向键 / WASD 移动  ·  点击地面行走  ·  Z 撤销  ·  R 重来  ·  Esc 菜单", 16, 400, Color(UiKit.ink, 0.5))
	add_child(foot)
	UiKit.pin(foot, 0.0, 1.0, 132, -48)
	UiKit.appear(foot, 0.8)
	var credit := UiKit.label("郭城（Iwan）", 15, 400, Color(UiKit.ink, 0.4))
	add_child(credit)
	UiKit.pin(credit, 1.0, 1.0, -64, -48)


func focus_first() -> void:
	if _first_button:
		_first_button.grab_focus()
