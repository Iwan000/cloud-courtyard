class_name Character
extends Node3D
## 斗笠旅人：程序几何拼装的原创角色。
##
## 姿态由几个参数驱动（行走相位、前倾、挤压），动画逻辑见 BoardView；
## 本节点自身负责待机呼吸、腿部摆动与围巾的二级运动。

const HIP_Y := 0.17

var pivot: Node3D           ## 整体姿态（前倾、挤压拉伸）
var body: Node3D            ## 上半身（呼吸起伏）
var leg_l: Node3D
var leg_r: Node3D
var arm_l: Node3D
var arm_r: Node3D
var hat: Node3D
var scarf: Array[Node3D] = []

var walk_amount := 0.0      ## 0 = 站立，1 = 行走中
var walk_phase := 0.0
var push_amount := 0.0      ## 推箱姿态（前倾 + 伸手）
var cheer := 0.0            ## 欢呼

var _t := 0.0
var _scarf_angles: Array[float] = []
var _scarf_vel: Array[float] = []
var _last_pos := Vector3.ZERO
var _last_yaw := 0.0


func build(mats: ThemePalette.MaterialLib) -> void:
	pivot = Node3D.new()
	pivot.name = "Pivot"
	pivot.scale = Vector3.ONE * 1.45
	add_child(pivot)

	leg_l = _part(pivot, "LegL", Vector3(-0.055, HIP_Y, 0), _leg_mesh(mats))
	leg_r = _part(pivot, "LegR", Vector3(0.055, HIP_Y, 0), _leg_mesh(mats))

	body = Node3D.new()
	body.name = "Body"
	pivot.add_child(body)
	_part(body, "Cloak", Vector3.ZERO, _cloak_mesh(mats))
	_part(body, "Head", Vector3.ZERO, _head_mesh(mats))
	arm_l = _part(body, "ArmL", Vector3(-0.1, 0.42, -0.02), _arm_mesh(mats))
	arm_r = _part(body, "ArmR", Vector3(0.1, 0.42, -0.02), _arm_mesh(mats))
	hat = _part(body, "Hat", Vector3.ZERO, _hat_mesh(mats))

	# 围巾：从颈后垂下的 4 段链条
	var parent: Node3D = body
	var at := Vector3(0, 0.5, 0.06)
	for i in 4:
		var seg := _part(parent, "Scarf%d" % i, at, _scarf_mesh(mats, i))
		scarf.append(seg)
		_scarf_angles.append(0.0)
		_scarf_vel.append(0.0)
		parent = seg
		at = Vector3(0, 0, 0.075)
	_last_pos = global_position if is_inside_tree() else position


func _part(parent: Node3D, part_name: String, pos: Vector3, mesh: Mesh) -> Node3D:
	var holder := Node3D.new()
	holder.name = part_name
	holder.position = pos
	parent.add_child(holder)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	holder.add_child(mi)
	return holder


# ---------------------------------------------------------------------------
# 几何
# ---------------------------------------------------------------------------

func _leg_mesh(mats: ThemePalette.MaterialLib) -> ArrayMesh:
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	k.box(Vector3(-0.024, -HIP_Y, -0.024), Vector3(0.024, 0.0, 0.024), MeshKit.FACES_ALL)
	var m := ArrayMesh.new()
	k.commit_to(m, mats.get_mat("legs"))
	return m


func _cloak_mesh(mats: ThemePalette.MaterialLib) -> ArrayMesh:
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	k.lathe(PackedVector2Array([
		Vector2(0.2, 0.1), Vector2(0.215, 0.15), Vector2(0.16, 0.3), Vector2(0.1, 0.44), Vector2(0.065, 0.5),
	]), Vector3.ZERO, 8, PI / 8.0, true)
	var m := ArrayMesh.new()
	k.commit_to(m, mats.get_mat("cloak"))
	return m


func _head_mesh(mats: ThemePalette.MaterialLib) -> ArrayMesh:
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	var prof := PackedVector2Array()
	var r := 0.082
	for i in range(7):
		var a := PI * i / 6.0
		prof.append(Vector2(sin(a) * r, 0.565 - cos(a) * r))
	k.lathe(prof, Vector3.ZERO, 8, 0.0)
	var m := ArrayMesh.new()
	k.commit_to(m, mats.get_mat("skin"))
	return m


func _hat_mesh(mats: ThemePalette.MaterialLib) -> ArrayMesh:
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	k.lathe(PackedVector2Array([
		Vector2(0.235, 0.6), Vector2(0.22, 0.615), Vector2(0.13, 0.67), Vector2(0.04, 0.75), Vector2(0.0, 0.775),
	]), Vector3.ZERO, 12, 0.0, true)
	var m := ArrayMesh.new()
	k.commit_to(m, mats.get_mat("hat"))
	return m


func _arm_mesh(mats: ThemePalette.MaterialLib) -> ArrayMesh:
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	k.box(Vector3(-0.026, -0.17, -0.026), Vector3(0.026, 0.0, 0.026), MeshKit.FACES_ALL)
	var m := ArrayMesh.new()
	k.commit_to(m, mats.get_mat("cloak"))
	return m


func _scarf_mesh(mats: ThemePalette.MaterialLib, i: int) -> ArrayMesh:
	var k := MeshKit.new()
	k.uv2 = Vector2.ZERO
	var w := 0.075 - i * 0.008
	k.box(Vector3(-w * 0.5, -0.012, 0.0), Vector3(w * 0.5, 0.012, 0.08), MeshKit.FACES_ALL)
	var m := ArrayMesh.new()
	k.commit_to(m, mats.get_mat("scarf"))
	return m


# ---------------------------------------------------------------------------
# 朝向与动画
# ---------------------------------------------------------------------------

## 朝向网格方向（模型正前方为本地 -Z）。
static func yaw_for_dir(d: Vector2i) -> float:
	return atan2(-float(d.x), -float(d.y))


func _process(delta: float) -> void:
	_t += delta
	# 腿：行走时交替摆动
	var swing := sin(walk_phase) * 0.75 * walk_amount
	leg_l.rotation.x = swing
	leg_r.rotation.x = -swing
	# 手臂：推箱时向前伸，行走时轻摆，欢呼时上举
	var arm_push := 1.25 * push_amount
	var arm_cheer := 2.6 * cheer
	arm_l.rotation.x = arm_push + arm_cheer - swing * 0.6
	arm_r.rotation.x = arm_push + arm_cheer + swing * 0.6
	arm_l.rotation.z = -0.12 - 0.35 * cheer
	arm_r.rotation.z = 0.12 + 0.35 * cheer
	# 呼吸
	var breath := sin(_t * 2.2) * 0.012 * (1.0 - walk_amount)
	body.position.y = breath + absf(sin(walk_phase)) * 0.02 * walk_amount
	pivot.rotation.x = -0.22 * push_amount - 0.05 * walk_amount
	hat.rotation.z = sin(_t * 1.3) * 0.02

	# 围巾：由移动速度与转身驱动的弹簧链
	var pos := global_position
	var vel := (pos - _last_pos) / maxf(delta, 1e-4)
	_last_pos = pos
	var local_vel := global_basis.inverse() * vel
	var yaw_rate := wrapf(rotation.y - _last_yaw, -PI, PI) / maxf(delta, 1e-4)
	_last_yaw = rotation.y
	var drive := clampf(-local_vel.z * 0.9, -0.6, 1.2) + 0.15 * sin(_t * 1.7)
	for i in scarf.size():
		var target := 0.35 + 0.15 * i + drive * (0.5 + 0.2 * i)
		target += sin(_t * 3.0 + i * 0.9) * 0.06 * (1.0 + walk_amount)
		var a := _scarf_angles[i]
		var v := _scarf_vel[i]
		v += ((target - a) * 60.0 - v * 9.0) * delta
		a += v * delta
		_scarf_angles[i] = a
		_scarf_vel[i] = v
		scarf[i].rotation.x = clampf(a, -0.2, 1.4) * (1.0 if i == 0 else 0.35)
		scarf[i].rotation.y = clampf(yaw_rate * -0.02, -0.5, 0.5) * (i + 1) * 0.3
