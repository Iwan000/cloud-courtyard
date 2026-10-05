class_name Fx
extends Node3D
## 轻量粒子与光效：每个粒子是一个公告板面片，由 Tween 驱动位置、缩放与透明度。
## 数量都很少（每次几颗到几十颗），无需 GPU 粒子系统，且完全可控、易于调校。

const SPRITE_SHADER := preload("res://shaders/fx_sprite.gdshader")
const PILLAR_SHADER := preload("res://shaders/light_pillar.gdshader")

var _quad: QuadMesh
var _mats := {}       # shape -> ShaderMaterial
var _pillar_mesh: ArrayMesh
var _pillar_mat: ShaderMaterial
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE
	for shape in [0, 1, 2]:
		var m := ShaderMaterial.new()
		m.shader = SPRITE_SHADER
		m.set_shader_parameter("shape", shape)
		_mats[shape] = m
	_pillar_mesh = _square_frame_mesh(0.5)
	_pillar_mat = ShaderMaterial.new()
	_pillar_mat.shader = PILLAR_SHADER
	rng.randomize()


func _sprite(shape: int, pos: Vector3, size: float, color: Color, energy := 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _quad
	mi.material_override = _mats[shape]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	mi.scale = Vector3.ONE * size
	mi.set_instance_shader_parameter("tint", color)
	mi.set_instance_shader_parameter("energy", energy)
	add_child(mi)
	return mi


## 推箱时箱底扬起的尘土：沿推动方向的反侧散开。
func dust(at: Vector3, dir: Vector3, color: Color, count := 7) -> void:
	var side := Vector3(-dir.z, 0, dir.x)
	for i in count:
		var c := color
		c.a = rng.randf_range(0.35, 0.55)
		var start := at + side * rng.randf_range(-0.4, 0.4) + Vector3(0, 0.05, 0)
		var mi := _sprite(0, start, rng.randf_range(0.12, 0.2), c)
		var end := start - dir * rng.randf_range(0.1, 0.35) + side * rng.randf_range(-0.2, 0.2) \
			+ Vector3(0, rng.randf_range(0.12, 0.3), 0)
		var dur := rng.randf_range(0.45, 0.75)
		var tw := mi.create_tween().set_parallel()
		tw.tween_property(mi, "position", end, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(mi, "scale", Vector3.ONE * rng.randf_range(0.3, 0.45), dur).set_ease(Tween.EASE_OUT)
		tw.tween_method(func(a: float): _set_alpha(mi, c, a), c.a, 0.0, dur).set_ease(Tween.EASE_IN)
		tw.chain().tween_callback(mi.queue_free)


## 脚步的轻微尘土。
func footstep(at: Vector3, color: Color) -> void:
	var c := color
	c.a = 0.25
	var mi := _sprite(0, at + Vector3(0, 0.03, 0), 0.1, c)
	var tw := mi.create_tween().set_parallel()
	tw.tween_property(mi, "scale", Vector3.ONE * 0.22, 0.4).set_ease(Tween.EASE_OUT)
	tw.tween_property(mi, "position", mi.position + Vector3(0, 0.06, 0), 0.4)
	tw.tween_method(func(a: float): _set_alpha(mi, c, a), c.a, 0.0, 0.4)
	tw.chain().tween_callback(mi.queue_free)


## 光点上升（箱子入位、通关）。
func sparkles(at: Vector3, color: Color, count := 14, radius := 0.45, height := 1.4) -> void:
	for i in count:
		var ang := rng.randf() * TAU
		var r := rng.randf_range(0.1, radius)
		var start := at + Vector3(cos(ang) * r, rng.randf_range(0.0, 0.2), sin(ang) * r)
		var c := color
		c.a = 1.0
		var shape := 2 if rng.randf() < 0.35 else 0
		var mi := _sprite(shape, start, rng.randf_range(0.05, 0.1) * (1.6 if shape == 2 else 1.0), c, 2.2)
		var dur := rng.randf_range(0.9, 1.6)
		var end := start + Vector3(rng.randf_range(-0.1, 0.1), rng.randf_range(height * 0.5, height), rng.randf_range(-0.1, 0.1))
		var tw := mi.create_tween().set_parallel()
		tw.tween_property(mi, "position", end, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_method(func(a: float): _set_alpha(mi, c, a), 1.0, 0.0, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.chain().tween_callback(mi.queue_free)


## 方形光框：沿印记的方形外缘竖起的四面光幕（高 1，底边中心在原点），与石箱的方形轮廓一致。
static func _square_frame_mesh(half: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector3(-half, 0, -half), Vector3(half, 0, -half), Vector3(half, 0, half), Vector3(-half, 0, half)]
	for i in 4:
		var a: Vector3 = corners[i]
		var b: Vector3 = corners[(i + 1) % 4]
		var u0 := i * 0.25
		var u1 := u0 + 0.25
		# UV.y：0 在顶部，1 在底部（光幕自下而上淡出）
		var quad := [[a + Vector3(0, -0.5, 0), Vector2(u0, 1)], [b + Vector3(0, -0.5, 0), Vector2(u1, 1)],
			[b + Vector3(0, 0.5, 0), Vector2(u1, 0)], [a + Vector3(0, 0.5, 0), Vector2(u0, 0)]]
		for k in [0, 1, 2, 0, 2, 3]:
			st.set_uv(quad[k][1])
			st.add_vertex(quad[k][0])
	return st.commit()


## 光框：自地面升起后淡出。
func light_pillar(at: Vector3, color: Color, height := 2.6) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _pillar_mesh
	mi.material_override = _pillar_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pillar_mat.set_shader_parameter("color", color)
	mi.position = at
	mi.scale = Vector3(1, 0.01, 1)
	add_child(mi)
	mi.set_instance_shader_parameter("intensity", 1.0)
	var tw := mi.create_tween()
	tw.set_parallel()
	tw.tween_property(mi, "scale", Vector3(1.0, height, 1.0), 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mi, "position", at + Vector3(0, height * 0.5, 0), 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.chain().tween_method(func(v: float): mi.set_instance_shader_parameter("intensity", v), 1.0, 0.0, 0.9)
	tw.chain().tween_callback(mi.queue_free)


## 花瓣飘散（通关时树开花）。
func petals(at: Vector3, color: Color, count := 18) -> void:
	for i in count:
		var c := color
		c.a = 0.95
		var start := at + Vector3(rng.randf_range(-0.35, 0.35), rng.randf_range(-0.1, 0.3), rng.randf_range(-0.35, 0.35))
		var mi := _sprite(1, start, rng.randf_range(0.07, 0.11), c, 1.0)
		var dur := rng.randf_range(2.2, 3.6)
		var drift := Vector3(rng.randf_range(-1.6, 0.4), rng.randf_range(-2.2, -1.0), rng.randf_range(-0.4, 1.6))
		var tw := mi.create_tween().set_parallel()
		tw.tween_property(mi, "position", start + drift, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_method(func(a: float): _set_alpha(mi, c, a), 0.95, 0.0, dur).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
		tw.chain().tween_callback(mi.queue_free)


## 平静飘浮的环境光尘（常驻），返回节点以便清理。
func ambient_motes(center: Vector3, extent: Vector2, color: Color, count := 22) -> Node3D:
	var root := Node3D.new()
	root.name = "Motes"
	add_child(root)
	for i in count:
		var c := color
		c.a = rng.randf_range(0.25, 0.6)
		var mi := MeshInstance3D.new()
		mi.mesh = _quad
		mi.material_override = _mats[0]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.scale = Vector3.ONE * rng.randf_range(0.04, 0.08)
		mi.set_instance_shader_parameter("tint", c)
		mi.set_instance_shader_parameter("energy", 1.4)
		var base := center + Vector3(rng.randf_range(-extent.x, extent.x), rng.randf_range(0.2, 2.6), rng.randf_range(-extent.y, extent.y))
		mi.position = base
		root.add_child(mi)
		var tw := mi.create_tween().set_loops()
		var dur := rng.randf_range(4.0, 7.0)
		tw.tween_property(mi, "position", base + Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(0.3, 0.7), rng.randf_range(-0.4, 0.4)), dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(mi, "position", base, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return root


func _set_alpha(mi: MeshInstance3D, c: Color, a: float) -> void:
	if is_instance_valid(mi):
		var col := c
		col.a = a
		mi.set_instance_shader_parameter("tint", col)
