class_name OverlayPanel
extends Control
## 弹出层基类：模糊背景 + 居中面板，带淡入/淡出动画。

const BLUR_SHADER := preload("res://shaders/ui_blur.gdshader")

signal closed

var backdrop: ColorRect
var panel: PanelContainer
var content: VBoxContainer
var _blur_mat: ShaderMaterial


func build_base(width := 560.0) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop = ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blur_mat = ShaderMaterial.new()
	_blur_mat.shader = BLUR_SHADER
	_blur_mat.set_shader_parameter("amount", 0.0)
	backdrop.material = _blur_mat
	add_child(backdrop)
	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiKit.panel_style(0.7))
	panel.custom_minimum_size.x = width
	add_child(panel)
	UiKit.pin(panel, 0.5, 0.5)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	panel.add_child(content)


func open() -> void:
	visible = true
	panel.modulate.a = 0.0
	panel.scale = Vector2.ONE * 0.97
	panel.pivot_offset = panel.size * 0.5
	var tw := create_tween().set_parallel()
	tw.tween_method(func(v): _blur_mat.set_shader_parameter("amount", v), 0.0, 1.0, 0.35)
	tw.tween_property(panel, "modulate:a", 1.0, 0.3)
	tw.tween_property(panel, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func close() -> void:
	var tw := create_tween().set_parallel()
	tw.tween_method(func(v): _blur_mat.set_shader_parameter("amount", v), 1.0, 0.0, 0.25)
	tw.tween_property(panel, "modulate:a", 0.0, 0.2)
	await tw.finished
	visible = false
	closed.emit()


func add_title(text: String, en := "") -> void:
	content.add_child(UiKit.label(text, 38, 600))
	if en != "":
		content.add_child(UiKit.label(en, 22, 400, Color(UiKit.ink, 0.65), true, true))
	var sp := Control.new()
	sp.custom_minimum_size.y = 14
	content.add_child(sp)


func add_button(text: String, cb: Callable, size := 26) -> MvButton:
	var b := UiKit.text_button(text, size)
	b.pressed.connect(cb)
	content.add_child(b)
	return b
