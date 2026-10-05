class_name PauseMenu
extends OverlayPanel
## 暂停菜单。

signal resume
signal restart
signal settings
signal to_select
signal to_title

var _first: MvButton


func build(in_editor_test := false) -> void:
	build_base(480)
	add_title("片刻休憩", "Paused")
	_first = add_button("继续", func(): resume.emit())
	add_button("重新开始", func(): restart.emit())
	add_button("设置", func(): settings.emit())
	if in_editor_test:
		add_button("返回编辑器", func(): to_select.emit())
	else:
		add_button("返回选关", func(): to_select.emit())
		add_button("返回标题", func(): to_title.emit())


func open() -> void:
	super.open()
	_first.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if visible and (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		resume.emit()
		get_viewport().set_input_as_handled()
