class_name EditorToolButton
extends Button
## 编辑器工具按钮：左侧画一个与游戏同色的小图标，右侧是名称与快捷键。

var tool_id := 0
var caption := ""
var hotkey := ""
var colors: Array[Color] = []
var selected := false:
	set(v):
		selected = v
		queue_redraw()
var _hover := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(196, 58)
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func(): Sfx.play("ui_hover"))


func _process(delta: float) -> void:
	var t := 1.0 if is_hovered() else 0.0
	if not is_equal_approx(_hover, t):
		_hover = move_toward(_hover, t, delta * 6.0)
		queue_redraw()


func _draw() -> void:
	var ink := UiKit.ink
	var bg_a := 0.0
	if selected:
		bg_a = 0.75
	elif _hover > 0.0:
		bg_a = 0.35 * _hover
	if bg_a > 0.0:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, bg_a)
		sb.set_corner_radius_all(14)
		if selected:
			sb.border_color = Color(UiKit.accent, 0.8)
			sb.set_border_width_all(2)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
	var c := Vector2(32, size.y * 0.5)
	_draw_icon(c)
	var font := UiKit.font(500)
	draw_string(font, Vector2(64, size.y * 0.5 + 8), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, ink)
	var f2 := UiKit.font(500)
	draw_string(f2, Vector2(size.x - 30, size.y * 0.5 + 7), hotkey, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(ink, 0.45))


## 等轴小方块：top/left/right 三色
func _iso_block(c: Vector2, w: float, h: float, cols: Array[Color]) -> void:
	var top := PackedVector2Array([c + Vector2(0, -w * 0.5 - h), c + Vector2(w, -h), c + Vector2(0, w * 0.5 - h), c + Vector2(-w, -h)])
	var left := PackedVector2Array([c + Vector2(-w, -h), c + Vector2(0, w * 0.5 - h), c + Vector2(0, w * 0.5), c + Vector2(-w, 0)])
	var right := PackedVector2Array([c + Vector2(0, w * 0.5 - h), c + Vector2(w, -h), c + Vector2(w, 0), c + Vector2(0, w * 0.5)])
	draw_colored_polygon(left, cols[1])
	draw_colored_polygon(right, cols[2])
	draw_colored_polygon(top, cols[0])


func _draw_icon(c: Vector2) -> void:
	match tool_id:
		LevelEditor.Tool.FLOOR:
			_iso_block(c + Vector2(0, 6), 16, 4, colors)
		LevelEditor.Tool.WALL:
			_iso_block(c + Vector2(0, 10), 13, 16, colors)
		LevelEditor.Tool.BOX:
			_iso_block(c + Vector2(0, 9), 12, 13, colors)
		LevelEditor.Tool.TARGET:
			var top := PackedVector2Array([c + Vector2(0, -8), c + Vector2(16, 0), c + Vector2(0, 8), c + Vector2(-16, 0)])
			draw_colored_polygon(top, colors[0])
			draw_arc(c, 5.5, 0, TAU, 24, Color.WHITE, 2.0, true)
			draw_set_transform(c, 0, Vector2(1, 0.5))
			draw_arc(Vector2.ZERO, 10, 0, TAU, 24, Color(Color.WHITE, 0.8), 2.0, true)
			draw_set_transform(Vector2.ZERO)
		LevelEditor.Tool.PLAYER:
			# 棋子小兵剪影：底座 + 身体 + 领环 + 圆头
			draw_rect(Rect2(c + Vector2(-9, 9), Vector2(18, 4)), colors[1])
			draw_colored_polygon(PackedVector2Array([c + Vector2(-6, 9), c + Vector2(6, 9), c + Vector2(3, -2), c + Vector2(-3, -2)]), colors[0])
			draw_rect(Rect2(c + Vector2(-5, -4), Vector2(10, 3)), colors[1])
			draw_circle(c + Vector2(0, -9), 5.5, colors[0])
		LevelEditor.Tool.ERASE:
			draw_line(c + Vector2(-9, -9), c + Vector2(9, 9), Color(UiKit.ink, 0.8), 2.5, true)
			draw_line(c + Vector2(9, -9), c + Vector2(-9, 9), Color(UiKit.ink, 0.8), 2.5, true)
