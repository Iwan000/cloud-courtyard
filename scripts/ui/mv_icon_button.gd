class_name MvIconButton
extends Button
## 线条图标按钮（矢量绘制，不依赖图标字体）：undo / redo / restart / menu / back / hint / close / play / sound。

var icon_name := "menu"
var icon_color := Color(-1, 0, 0)
var _hover := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(56, 56)
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func(): Sfx.play("ui_hover"))
	pressed.connect(func(): Sfx.play("ui_click"))


func _process(delta: float) -> void:
	var target := 1.0 if is_hovered() and not disabled else 0.0
	if not is_equal_approx(_hover, target):
		_hover = move_toward(_hover, target, delta * 6.0)
		queue_redraw()


func _draw() -> void:
	var c := UiKit.ink if icon_color.r < 0 else icon_color
	var center := size * 0.5
	# 悬停底圆
	draw_circle(center, 25.0, Color(1, 1, 1, 0.35 + 0.35 * _hover))
	draw_arc(center, 25.0, 0, TAU, 48, Color(c, 0.15 + 0.25 * _hover), 1.0, true)
	var a := Color(c, 0.45 if disabled else 0.9)
	var w := 2.0
	var r := 10.0
	match icon_name:
		"undo", "redo":
			# 从右下起、经顶部、到左下止的圆弧（重做为镜像），箭头沿终点切线方向
			var mirror := 1.0 if icon_name == "undo" else -1.0
			var a0 := deg_to_rad(-40.0)
			var a1 := deg_to_rad(200.0)
			var pts := PackedVector2Array()
			for i in range(17):
				var th := lerpf(a0, a1, i / 16.0)
				pts.append(center + Vector2(cos(th) * mirror, -sin(th)) * r + Vector2(0, 2))
			draw_polyline(pts, a, w, true)
			var tip := pts[pts.size() - 1]
			var dir := (tip - pts[pts.size() - 2]).normalized()
			draw_line(tip, tip - dir.rotated(0.6) * 6.0, a, w, true)
			draw_line(tip, tip - dir.rotated(-0.6) * 6.0, a, w, true)
		"restart":
			# 留出右上缺口的四分之三圆弧，箭头沿终点切线
			var pts := PackedVector2Array()
			var a0 := deg_to_rad(60.0)
			var a1 := deg_to_rad(330.0)
			for i in range(19):
				var th := lerpf(a0, a1, i / 18.0)
				pts.append(center + Vector2(cos(th), sin(th)) * r)
			draw_polyline(pts, a, w, true)
			var tip := pts[pts.size() - 1]
			var dir := (tip - pts[pts.size() - 2]).normalized()
			draw_line(tip, tip - dir.rotated(0.6) * 6.0, a, w, true)
			draw_line(tip, tip - dir.rotated(-0.6) * 6.0, a, w, true)
		"menu":
			for k in [-6, 0, 6]:
				draw_line(center + Vector2(-9, k), center + Vector2(9, k), a, w, true)
		"back":
			draw_line(center + Vector2(4, -8), center + Vector2(-4, 0), a, w, true)
			draw_line(center + Vector2(-4, 0), center + Vector2(4, 8), a, w, true)
		"close":
			draw_line(center + Vector2(-7, -7), center + Vector2(7, 7), a, w, true)
			draw_line(center + Vector2(7, -7), center + Vector2(-7, 7), a, w, true)
		"play":
			draw_colored_polygon(PackedVector2Array([center + Vector2(-5, -8), center + Vector2(8, 0), center + Vector2(-5, 8)]), a)
		"hint":
			draw_arc(center + Vector2(0, -3), 7, PI * 0.8, PI * 2.2, 24, a, w, true)
			draw_line(center + Vector2(-3, 5), center + Vector2(3, 5), a, w, true)
			draw_line(center + Vector2(-2, 9), center + Vector2(2, 9), a, w, true)
		"grid":
			for i in 3:
				for j in 3:
					draw_rect(Rect2(center + Vector2(-9 + i * 6.5, -9 + j * 6.5), Vector2(4.5, 4.5)), a)
		_:
			draw_circle(center, 4, a)
