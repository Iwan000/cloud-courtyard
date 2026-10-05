class_name SettingsPanel
extends OverlayPanel
## 设置：音乐 / 音效音量、全屏、画面颗粒、重置进度。

var _first: Control


func build() -> void:
	build_base(560)
	add_title("设置", "Settings")
	_first = _slider_row("音乐", "music")
	_slider_row("音效", "sfx")
	_toggle_row("全屏", "fullscreen")
	_toggle_row("纸张颗粒", "grain")
	var sp := Control.new()
	sp.custom_minimum_size.y = 10
	content.add_child(sp)
	var reset := add_button("重置通关进度", func(): pass, 20)
	reset.pressed.connect(func():
		if reset.text == "重置通关进度":
			reset.text = "再点一次确认重置"
		else:
			Game.reset_progress()
			reset.text = "进度已重置")
	add_button("完成", func(): close(), 26)


func _slider_row(caption: String, key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	var l := UiKit.label(caption, 24, 500)
	l.custom_minimum_size.x = 130
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = float(Game.settings[key])
	s.custom_minimum_size = Vector2(300, 40)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(func(v: float):
		Game.set_setting(key, v)
		if key == "sfx":
			Sfx.play("ui_hover"))
	row.add_child(s)
	content.add_child(row)
	return s


func _toggle_row(caption: String, key: String) -> void:
	var b := UiKit.text_button("", 24)
	var refresh := func(): b.text = "%s    %s" % [caption, "开" if Game.settings[key] else "关"]
	refresh.call()
	b.pressed.connect(func():
		Game.set_setting(key, not Game.settings[key])
		refresh.call())
	content.add_child(b)


func open() -> void:
	super.open()
	_first.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if visible and (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		close()
		get_viewport().set_input_as_handled()
