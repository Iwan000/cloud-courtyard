class_name CompletePanel
extends Control
## 通关结算：庭院已苏醒。显示步数与最佳记录，以及三枚花瓣评价（分档见 LevelData.grade_limits）。
## 不显示全局最优步数；未得三瓣时给出三瓣的步数范围作为目标。

const SHADE_SHADER := preload("res://shaders/ui_bottom_shade.gdshader")

signal next_pressed
signal replay_pressed
signal select_pressed

var _first: MvButton


func build(lvl: LevelData, moves: int, _pushes: int, best: int, new_record: bool, has_next: bool, in_editor_test := false) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 底部柔和渐变底，衬托文字
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sm := ShaderMaterial.new()
	sm.shader = SHADE_SHADER
	var night := UiKit.ink.get_luminance() > 0.6
	sm.set_shader_parameter("tint", Color(0.08, 0.07, 0.22) if night else Color(1, 1, 1))
	shade.material = sm
	add_child(shade)
	shade.modulate.a = 0.0
	shade.create_tween().tween_property(shade, "modulate:a", 1.0, 1.0)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 4)
	add_child(box)
	UiKit.pin(box, 0.5, 1.0, 0, -64)

	var title := UiKit.glow(UiKit.label("庭院已苏醒", 48, 700))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var rating := lvl.petals_for(moves)
	var petals := Petals.new()
	petals.count = rating
	petals.custom_minimum_size = Vector2(180, 54)
	petals.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(petals)

	var parts: Array[String] = ["步数 %d" % moves]
	if best > 0:
		parts.append(("新纪录" if new_record else "最佳 %d" % best))
	if rating < 3:
		parts.append("三瓣：%d 步以内" % lvl.grade_limits().x)
	var stats := UiKit.label("    ·    ".join(parts), 21, 500, Color(UiKit.ink, 0.75))
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(stats)
	var sp := Control.new()
	sp.custom_minimum_size.y = 18
	box.add_child(sp)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 56)
	if in_editor_test:
		var b0 := UiKit.text_button("返回编辑器", 28)
		b0.pressed.connect(func(): select_pressed.emit())
		row.add_child(b0)
		_first = b0
	else:
		var b1 := UiKit.text_button("返回选关", 24)
		b1.pressed.connect(func(): select_pressed.emit())
		row.add_child(b1)
	var b2 := UiKit.text_button("再走一次", 24)
	b2.pressed.connect(func(): replay_pressed.emit())
	row.add_child(b2)
	if has_next and not in_editor_test:
		var b3 := UiKit.text_button("下一座庭院", 30)
		b3.pressed.connect(func(): next_pressed.emit())
		row.add_child(b3)
		_first = b3
	if _first == null:
		_first = b2
	box.add_child(row)

	var d := 0.0
	for c in box.get_children():
		UiKit.appear(c, d)
		d += 0.12
	petals.play(0.45)


func focus_default() -> void:
	if _first:
		_first.grab_focus()


## 评价：不超过参考步数 3 瓣，不超过 1.3 倍 2 瓣，其余 1 瓣。
class Petals:
	extends Control
	## 三枚花瓣（菱形），获得的依次点亮。
	var count := 3
	var _t := 0.0
	var _start := 99.0

	func play(delay: float) -> void:
		_start = delay
		_t = 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		for i in 3:
			var x := c.x + (i - 1) * 46.0
			var k := clampf((_t - _start - i * 0.22) / 0.35, 0.0, 1.0)
			var e := 1.0 - pow(1.0 - k, 3.0)
			var on := i < count
			var r := 13.0 * (0.6 + 0.4 * e) if on else 10.0
			var col := Color(UiKit.accent, e) if on else Color(UiKit.ink, 0.2)
			var p := Vector2(x, c.y)
			var pts := PackedVector2Array([p + Vector2(0, -r * 1.25), p + Vector2(r, 0), p + Vector2(0, r * 1.25), p + Vector2(-r, 0)])
			if on:
				draw_colored_polygon(pts, col)
				if e > 0.0 and e < 1.0:
					draw_arc(p, r * (1.0 + e * 1.4), 0, TAU, 32, Color(UiKit.accent, (1.0 - e) * 0.6), 1.5, true)
			else:
				pts.append(pts[0])
				draw_polyline(pts, col, 1.5, true)
