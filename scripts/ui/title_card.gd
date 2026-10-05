class_name TitleCard
extends Control
## 关卡开场的章节标题卡：罗马数字 + 关卡名，淡入后淡出。


func show_card(numeral: String, title: String) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	add_child(box)
	UiKit.pin(box, 0.5, 0.0, 0, 150)
	if numeral != "":
		var n := UiKit.glow(UiKit.label(numeral, 28, 500, Color(UiKit.ink, 0.6)), 0.5, 12)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(n)
	var t := UiKit.glow(UiKit.label(title, 58, 700), 0.6, 18)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.9).set_trans(Tween.TRANS_SINE)
	tw.tween_interval(1.6)
	tw.tween_property(self, "modulate:a", 0.0, 1.0).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(queue_free)
