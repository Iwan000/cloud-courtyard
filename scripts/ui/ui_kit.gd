class_name UiKit
extends RefCounted
## UI 风格套件：字体、配色、Theme，以及常用控件的构造函数。
## 视觉语言：衬线字体、纯文字按钮（悬停时下划线从中间展开）、半透明白色面板、细线分隔。

const FONT_CJK_PATH := "res://fonts/NotoSerifSC-Subset.ttf"
const FONT_LATIN_PATH := "res://fonts/CormorantGaramond-Subset.ttf"
const FONT_LATIN_ITALIC_PATH := "res://fonts/CormorantGaramond-Italic-Subset.ttf"

static var _fonts := {}
static var ink := Color("4b3d5e")          ## 主文字色（随主题变化）
static var ink_soft := Color("4b3d5e", 0.62)
static var accent := Color("e07a86")


static func _font_file(path: String) -> Font:
	if ResourceLoader.exists(path):
		return load(path)
	return ThemeDB.fallback_font


## weight: 300~900；latin=true 使用西文衬线字体（中文自动回退到思源宋体）。
static func font(weight := 400, latin := false, italic := false) -> Font:
	var key := "%d_%s_%s" % [weight, latin, italic]
	if _fonts.has(key):
		return _fonts[key]
	var cjk := _font_file(FONT_CJK_PATH)
	var fv := FontVariation.new()
	if latin:
		fv.base_font = _font_file(FONT_LATIN_ITALIC_PATH if italic else FONT_LATIN_PATH)
		fv.fallbacks = [cjk]
	else:
		fv.base_font = cjk
	fv.variation_opentype = {"wght": weight}
	_fonts[key] = fv
	return fv


## 根据主题设置文字颜色（夜景用浅色）。
static func set_theme_colors(theme: Dictionary) -> void:
	var night: bool = Color(theme["sky_top"]).get_luminance() < 0.3
	if night:
		ink = Color("f4f0ff")
	else:
		ink = Color("4b3d5e").lerp(Color(theme["deep"]).darkened(0.55), 0.35)
	ink_soft = Color(ink, 0.62)
	accent = Color(theme["target"])


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(400)
	t.default_font_size = 22
	t.set_color("font_color", "Label", ink)
	for cls in ["Button", "CheckBox", "LineEdit", "OptionButton"]:
		t.set_color("font_color", cls, ink)
		t.set_color("font_hover_color", cls, ink)
		t.set_color("font_pressed_color", cls, ink)
		t.set_color("font_focus_color", cls, ink)
		t.set_color("font_disabled_color", cls, Color(ink, 0.35))
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		t.set_stylebox(st, "Button", empty)
	# 输入框
	var le := StyleBoxFlat.new()
	le.bg_color = Color(1, 1, 1, 0.55)
	le.set_corner_radius_all(10)
	le.content_margin_left = 14
	le.content_margin_right = 14
	le.content_margin_top = 6
	le.content_margin_bottom = 6
	le.border_color = Color(ink, 0.25)
	le.set_border_width_all(1)
	t.set_stylebox("normal", "LineEdit", le)
	var lef := le.duplicate() as StyleBoxFlat
	lef.border_color = Color(ink, 0.6)
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_color("caret_color", "LineEdit", ink)
	t.set_color("selection_color", "LineEdit", Color(accent, 0.35))
	# 滑条
	var track := StyleBoxFlat.new()
	track.bg_color = Color(ink, 0.18)
	track.set_corner_radius_all(3)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	t.set_stylebox("slider", "HSlider", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(ink, 0.7)
	fill.set_corner_radius_all(3)
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_icon("grabber", "HSlider", _dot_texture(18, ink))
	t.set_icon("grabber_highlight", "HSlider", _dot_texture(20, ink))
	# 滚动条
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(ink, 0.25)
	sb.set_corner_radius_all(4)
	t.set_stylebox("grabber", "VScrollBar", sb)
	t.set_stylebox("grabber_highlight", "VScrollBar", sb)
	t.set_stylebox("grabber_pressed", "VScrollBar", sb)
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())
	# 提示框
	var tip := StyleBoxFlat.new()
	tip.bg_color = Color(1, 1, 1, 0.9)
	tip.set_corner_radius_all(8)
	tip.content_margin_left = 10
	tip.content_margin_right = 10
	tip.content_margin_top = 4
	tip.content_margin_bottom = 4
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", ink)
	return t


static func _dot_texture(size: int, c: Color) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := size * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var a := clampf(r - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(c, a))
	return ImageTexture.create_from_image(img)


## 半透明白色面板
static func panel_style(alpha := 0.62, radius := 22) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1, 1, 1, alpha)
	s.set_corner_radius_all(radius)
	s.border_color = Color(1, 1, 1, minf(alpha + 0.25, 1.0))
	s.set_border_width_all(1)
	s.shadow_color = Color(0.25, 0.15, 0.35, 0.12)
	s.shadow_size = 24
	s.content_margin_left = 36
	s.content_margin_right = 36
	s.content_margin_top = 28
	s.content_margin_bottom = 28
	return s


static func label(text: String, size := 22, weight := 400, color := Color(0, 0, 0, 0), latin := false, italic := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(weight, latin, italic))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", ink if color.a == 0.0 else color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func text_button(text: String, size := 26, sub := "") -> MvButton:
	var b := MvButton.new()
	b.setup(text, size, sub)
	return b


static func icon_button(icon: String, tooltip := "") -> MvIconButton:
	var b := MvIconButton.new()
	b.icon_name = icon
	b.tooltip_text = tooltip
	return b


static func hline(width := 120.0, alpha := 0.35) -> Control:
	var c := ColorRect.new()
	c.color = Color(ink, alpha)
	c.custom_minimum_size = Vector2(width, 1)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## 淡入 + 轻微上移。容器内的控件只做淡入；独立控件等布局完成后再做位移，避免覆盖锚点布局。
static func appear(c: CanvasItem, delay := 0.0, dist := 16.0, dur := 0.6) -> void:
	c.modulate.a = 0.0
	var fade := c.create_tween()
	fade.tween_property(c, "modulate:a", 1.0, dur).set_delay(delay).set_trans(Tween.TRANS_SINE)
	if not (c is Control) or c.get_parent() is Container:
		return
	var ctl := c as Control
	await ctl.get_tree().process_frame
	if not is_instance_valid(ctl):
		return
	var base_top := ctl.offset_top
	var base_bottom := ctl.offset_bottom
	ctl.offset_top = base_top + dist
	ctl.offset_bottom = base_bottom + dist
	var tw := ctl.create_tween().set_parallel()
	tw.tween_property(ctl, "offset_top", base_top, dur).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(ctl, "offset_bottom", base_bottom, dur).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


static func roman(n: int) -> String:
	const R := ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
	return R[n] if n >= 0 and n < R.size() else str(n)


## 锚点定位：(ax, ay) 为父控件中的锚点比例，(ox, oy) 为偏移；控件按锚点所在侧自动决定生长方向。
static func pin(c: Control, ax: float, ay: float, ox := 0.0, oy := 0.0) -> void:
	c.anchor_left = ax
	c.anchor_right = ax
	c.anchor_top = ay
	c.anchor_bottom = ay
	c.offset_left = ox
	c.offset_right = ox
	c.offset_top = oy
	c.offset_bottom = oy
	c.grow_horizontal = Control.GROW_DIRECTION_END if ax < 0.25 else (Control.GROW_DIRECTION_BEGIN if ax > 0.75 else Control.GROW_DIRECTION_BOTH)
	c.grow_vertical = Control.GROW_DIRECTION_END if ay < 0.25 else (Control.GROW_DIRECTION_BEGIN if ay > 0.75 else Control.GROW_DIRECTION_BOTH)


## 给文字加一圈柔和的背景色光晕，保证在 3D 场景上可读。
static func glow(l: Label, alpha := 0.55, size := 14) -> Label:
	var night := ink.get_luminance() > 0.6
	l.add_theme_color_override("font_shadow_color", Color(0.1, 0.08, 0.25, alpha) if night else Color(1, 1, 1, alpha))
	l.add_theme_constant_override("shadow_outline_size", size)
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 0)
	return l
