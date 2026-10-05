class_name BoardView
extends Node3D
## 动态物件的表现层：目标地砖、箱子、角色。只根据 SokobanState / MoveResult 驱动。

var state: SokobanState
var mats: ThemePalette.MaterialLib
var character: Character
var box_nodes: Array[Node3D] = []
var target_nodes := {}   # Vector2i -> MeshInstance3D


static func cell_pos(p: Vector2i, y := 0.0) -> Vector3:
	return Vector3(p.x, y, p.y)


func setup(st: SokobanState, material_lib: ThemePalette.MaterialLib) -> void:
	state = st
	mats = material_lib
	for c in get_children():
		c.queue_free()
	box_nodes.clear()
	target_nodes.clear()
	var target_mesh := Props.make_target_mesh(mats)
	for t in st.level.target_list():
		var mi := MeshInstance3D.new()
		mi.mesh = target_mesh
		mi.position = cell_pos(t, 0.004)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		target_nodes[t] = mi
	var box_mesh := Props.make_box_mesh(mats)
	for i in st.boxes.size():
		var holder := Node3D.new()
		holder.name = "Box%d" % i
		var mi := MeshInstance3D.new()
		mi.mesh = box_mesh
		holder.add_child(mi)
		holder.position = cell_pos(st.boxes[i])
		add_child(holder)
		box_nodes.append(holder)
	character = Character.new()
	character.name = "Traveler"
	add_child(character)
	character.build(mats)
	character.position = cell_pos(st.player)
	character.rotation.y = Character.yaw_for_dir(Vector2i(0, 1))
	refresh_glow(true)


## 根据箱子是否在目标上设置发光。
func refresh_glow(instant := false) -> void:
	for t in target_nodes:
		var on := state.box_at(t) >= 0
		(target_nodes[t] as MeshInstance3D).set_instance_shader_parameter("glow", 1.0 if on else 0.0)
	for i in box_nodes.size():
		var on := state.level.is_target(state.boxes[i])
		var mi := box_nodes[i].get_child(0) as MeshInstance3D
		mi.set_instance_shader_parameter("glow", 1.0 if on else 0.0)
