class_name MvButton
extends Button
## 纯文字按钮：悬停/聚焦时下划线从中间展开，文字轻微右移；带音效。

var sub_text := ""
var _hover := 0.0
var _sub_label: Label
var font_size := 26


func setup(text_value: String, size := 26, sub := "") -> void:
	text = text_value
	font_size = size
	sub_text = sub
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_theme_font_override("font", UiKit.font(500))
	add_theme_font_size_override("font_size", size)
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size.y = size * 1.9
	mouse_entered.connect(_on_enter)
	focus_entered.connect(_on_enter)
	pressed.connect(func(): Sfx.play("ui_click"))


func _on_enter() -> void:
	if not disabled:
		Sfx.play("ui_hover")


func _process(delta: float) -> void:
	var target := 1.0 if (is_hovered() or has_focus()) and not disabled else 0.0
	if not is_equal_approx(_hover, target):
		_hover = move_toward(_hover, target, delta * 5.0)
		queue_redraw()


func _draw() -> void:
	if _hover <= 0.001:
		return
	var font := get_theme_font("font")
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var e := 1.0 - pow(1.0 - _hover, 3.0)
	var y := size.y * 0.5 + font_size * 0.62
	var c := Color(UiKit.ink, 0.75 * e)
	var cx := w * 0.5
	draw_line(Vector2(cx - cx * e, y), Vector2(cx + cx * e, y), c, 1.5, true)
	# 左侧小菱形
	var d := 5.0 * e
	var p := Vector2(-16, size.y * 0.5)
	draw_colored_polygon(PackedVector2Array([p + Vector2(0, -d), p + Vector2(d, 0), p + Vector2(0, d), p + Vector2(-d, 0)]), Color(UiKit.accent, e))
