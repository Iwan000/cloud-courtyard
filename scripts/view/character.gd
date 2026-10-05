class_name Character
extends Node3D
## 棋子小兵：程序生成的旋转体（底座、身体、领环、圆头），使用与场景相同的 MV 着色。
##
## 姿态参数由 BoardView 逐帧驱动：
##   lean        0~1：前倾程度（推箱时用头顶住石箱），绕底座前缘转动
##   walk_amount 0~1：行走中（落地时轻微挤压）
##   cheer       0~1：通关欢呼时原地转一圈
## 自身负责待机呼吸与挤压拉伸。

const LEAN_DEG := 27.0
const SCALE := 1.25
const BASE_R := 0.27 * SCALE

var lean := 0.0
var walk_amount := 0.0
var walk_phase := 0.0
var cheer := 0.0

var _pivot: Node3D      ## 位于底座前缘，前倾时绕它旋转
var _body: Node3D       ## 挤压拉伸与旋转
var _t := 0.0


func build(mats: ThemePalette.MaterialLib) -> void:
	_pivot = Node3D.new()
	_pivot.name = "LeanPivot"
	_pivot.position = Vector3(0, 0, -BASE_R)
	add_child(_pivot)
	_body = Node3D.new()
	_body.name = "Body"
	_body.position = Vector3(0, 0, BASE_R)
	_pivot.add_child(_body)

	var body := MeshKit.new()
	var accent := MeshKit.new()
	for k in [body, accent]:
		k.uv2 = Vector2.ZERO
	const SIDES := 12
	var a0 := PI / SIDES
	# 底座（点缀色）
	accent.lathe(PackedVector2Array([
		Vector2(0.26, 0.0), Vector2(0.27, 0.03), Vector2(0.27, 0.07), Vector2(0.235, 0.095), Vector2(0.2, 0.105),
	]), Vector3.ZERO, SIDES, a0, true)
	# 身体：向上收窄的弧形
	body.lathe(PackedVector2Array([
		Vector2(0.2, 0.105), Vector2(0.168, 0.135), Vector2(0.135, 0.22), Vector2(0.108, 0.34), Vector2(0.096, 0.44),
	]), Vector3.ZERO, SIDES, a0)
	# 领环（点缀色）
	accent.lathe(PackedVector2Array([
		Vector2(0.096, 0.44), Vector2(0.148, 0.455), Vector2(0.155, 0.485), Vector2(0.12, 0.505), Vector2(0.075, 0.515),
	]), Vector3.ZERO, SIDES, a0)
	# 圆头
	var head := PackedVector2Array()
	var cy := 0.645
	var r := 0.138
	for i in range(9):
		var a := lerpf(deg_to_rad(-62.0), PI * 0.5, i / 8.0)
		head.append(Vector2(cos(a) * r, cy + sin(a) * r))
	body.lathe(head, Vector3.ZERO, SIDES, a0)

	var mesh := ArrayMesh.new()
	body.commit_to(mesh, mats.get_mat("cloak"))
	accent.commit_to(mesh, mats.get_mat("hat"))
	var mi := MeshInstance3D.new()
	mi.name = "Pawn"
	mi.mesh = mesh
	mi.scale = Vector3.ONE * SCALE
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_body.add_child(mi)


## 朝向网格方向（本地 -Z 为前方）。
static func yaw_for_dir(d: Vector2i) -> float:
	return atan2(-float(d.x), -float(d.y))


func _process(delta: float) -> void:
	if _pivot == null:
		return
	_t += delta
	# 前倾：绕底座前缘转动（本地 -Z 为前方，绕 X 轴负方向旋转为前倾）
	_pivot.rotation.x = -deg_to_rad(LEAN_DEG) * _ease(lean)
	# 待机呼吸 + 行走落地挤压
	var breath := sin(_t * 2.2) * 0.012 * (1.0 - walk_amount)
	var land := maxf(0.0, -cos(walk_phase * 2.0)) * 0.07 * walk_amount
	_body.scale = Vector3(1.0 + land * 0.6, 1.0 + breath - land, 1.0 + land * 0.6)
	# 欢呼：原地转一圈
	_body.rotation.y = cheer * TAU


static func _ease(x: float) -> float:
	return x * x * (3.0 - 2.0 * x)
