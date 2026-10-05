class_name MvButton
extends Button
## 纯文字按钮：悬停/聚焦时下划线从中间展开，左侧出现小菱形；带音效。
## 可选前缀列（如关卡序号）：前缀在固定宽度的列中单独绘制，正文统一从列宽之后开始，
## 这样不同宽度的序号（I / III / IV）后面的名字也能左对齐。

var font_size := 26
var prefix := ""
var prefix_width := 0.0
var _hover := 0.0


func setup(text_value: String, px := 26) -> void:
	text = text_value
	font_size = px
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_theme_font_override("font", UiKit.font(500))
	add_theme_font_size_override("font_size", px)
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size.y = px * 1.9
	mouse_entered.connect(_on_enter)
	focus_entered.connect(_on_enter)
	pressed.connect(func(): Sfx.play("ui_click"))


## 设置前缀列：正文向右让出 width 像素，前缀画在这一列里。
func set_prefix(value: String, width: float) -> void:
	prefix = value
	prefix_width = width
	var pad := StyleBoxEmpty.new()
	pad.content_margin_left = width
	for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		add_theme_stylebox_override(st, pad)
	queue_redraw()


func _on_enter() -> void:
	if not disabled:
		Sfx.play("ui_hover")


func _process(delta: float) -> void:
	var target := 1.0 if (is_hovered() or has_focus()) and not disabled else 0.0
	if not is_equal_approx(_hover, target):
		_hover = move_toward(_hover, target, delta * 5.0)
		queue_redraw()


func _draw() -> void:
	var font := get_theme_font("font")
	if prefix != "":
		# 与 Button 正文相同的垂直居中方式，保证基线对齐
		var baseline := (size.y - font.get_height(font_size)) * 0.5 + font.get_ascent(font_size)
		draw_string(font, Vector2(0, baseline), prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			get_theme_color("font_disabled_color" if disabled else "font_color"))
	if _hover <= 0.001:
		return
	var w := prefix_width + font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var e := 1.0 - pow(1.0 - _hover, 3.0)
	var y := size.y * 0.5 + font_size * 0.62
	var c := Color(UiKit.ink, 0.75 * e)
	var cx := w * 0.5
	draw_line(Vector2(cx - cx * e, y), Vector2(cx + cx * e, y), c, 1.5, true)
	# 左侧小菱形
	var d := 5.0 * e
	var p := Vector2(-16, size.y * 0.5)
	draw_colored_polygon(PackedVector2Array([p + Vector2(0, -d), p + Vector2(d, 0), p + Vector2(0, d), p + Vector2(-d, 0)]), Color(UiKit.accent, e))
