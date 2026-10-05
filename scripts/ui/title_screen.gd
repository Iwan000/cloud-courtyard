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
	var title := UiKit.label("云上庭", 100, 700)
	box.add_child(title)
	var gap := Control.new()
	gap.custom_minimum_size.y = 22
	box.add_child(gap)
	box.add_child(UiKit.hline(200, 0.3))
	var gap2 := Control.new()
	gap2.custom_minimum_size.y = 26
	box.add_child(gap2)

	var next := Game.next_level_index()
	var started := false
	for l in Game.builtin:
		if Game.is_completed(l.id):
			started = true
	var start_text := "继续旅程" if started and next < Game.builtin.size() else "开始旅程"
	var items := [
		[start_text, start_pressed],
		["选择庭院", select_pressed],
		["关卡编辑器", editor_pressed],
		["设置", settings_pressed],
		["离开", quit_pressed],
	]
	var delay := 0.35
	for it in items:
		var b := UiKit.text_button(it[0], 28)
		var sig: Signal = it[1]
		b.pressed.connect(func(): sig.emit())
		box.add_child(b)
		UiKit.appear(b, delay)
		delay += 0.07
		if _first_button == null:
			_first_button = b
	UiKit.appear(title, 0.05)

	var credit := UiKit.label("郭城（Iwan）", 15, 400, Color(UiKit.ink, 0.35))
	add_child(credit)
	UiKit.pin(credit, 1.0, 1.0, -64, -48)


func focus_first() -> void:
	if _first_button:
		_first_button.grab_focus()
