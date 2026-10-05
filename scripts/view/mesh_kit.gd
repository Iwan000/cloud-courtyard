class_name MeshKit
extends RefCounted
## 程序几何工具：在 SurfaceTool 上添加平直着色（每个面独立法线）的几何体。
##
## 所有构件共享两个"画笔"状态：
##   color —— 顶点色，作为乘数参与着色（构件色差、窗洞暗部）
##   uv2   —— 入场动画参数：x = 延迟(0~1)，y = 升起幅度系数（0 表示不动）

var st := SurfaceTool.new()
var color := Color.WHITE
var uv2 := Vector2(0.0, 1.0)
var _count := 0


func _init() -> void:
	st.begin(Mesh.PRIMITIVE_TRIANGLES)


func is_empty() -> bool:
	return _count == 0


## 把已添加的几何作为一个 surface 提交到 mesh，并设置材质。
func commit_to(mesh: ArrayMesh, material: Material) -> void:
	if _count == 0:
		return
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_count = 0


# ---------------------------------------------------------------------------
# 基本图元
# ---------------------------------------------------------------------------

func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	# Godot 以顺时针为正面：若 (b-a)×(c-a) 与期望法线同向（逆时针），交换顶点
	if (b - a).cross(c - a).dot(n) > 0.0:
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_normal(n)
		st.set_color(color)
		st.set_uv2(uv2)
		st.add_vertex(v)
	_count += 3


func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	tri(a, b, c, n)
	tri(a, c, d, n)


## 凸多边形（扇形三角化）。
func poly(points: PackedVector3Array, n: Vector3) -> void:
	for i in range(1, points.size() - 1):
		tri(points[0], points[i], points[i + 1], n)


enum { FACE_PX = 1, FACE_NX = 2, FACE_PY = 4, FACE_NY = 8, FACE_PZ = 16, FACE_NZ = 32 }
const FACES_NO_BOTTOM := 1 | 2 | 4 | 16 | 32
const FACES_ALL := 63


## 轴对齐长方体。faces 为面掩码。
func box(mn: Vector3, mx: Vector3, faces: int = FACES_NO_BOTTOM) -> void:
	var x0 := mn.x; var y0 := mn.y; var z0 := mn.z
	var x1 := mx.x; var y1 := mx.y; var z1 := mx.z
	if faces & FACE_PY:
		quad(Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.UP)
	if faces & FACE_NY:
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3.DOWN)
	if faces & FACE_PX:
		quad(Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), Vector3.RIGHT)
	if faces & FACE_NX:
		quad(Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x0, y0, z1), Vector3.LEFT)
	if faces & FACE_PZ:
		quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.BACK)
	if faces & FACE_NZ:
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0), Vector3.FORWARD)


## 以中心和尺寸描述的长方体。
func box_c(center: Vector3, size: Vector3, faces: int = FACES_NO_BOTTOM) -> void:
	box(center - size * 0.5, center + size * 0.5, faces)


## 把 2D 多边形（u,v 坐标）沿 w 方向挤出 depth。u、v、w 需正交归一。
## 前盖位于 origin 平面（法线 -w），后盖位于 origin + w*depth（法线 +w）。
func extrude(poly2: PackedVector2Array, origin: Vector3, u: Vector3, v: Vector3, w: Vector3,
		depth: float, front_cap := true, back_cap := true) -> void:
	var n := poly2.size()
	if n < 3:
		return
	var pts_front := PackedVector3Array()
	var pts_back := PackedVector3Array()
	for p in poly2:
		var q := origin + u * p.x + v * p.y
		pts_front.append(q)
		pts_back.append(q + w * depth)
	var idx := Geometry2D.triangulate_polygon(poly2)
	if front_cap or back_cap:
		for t in range(0, idx.size(), 3):
			if front_cap:
				tri(pts_front[idx[t]], pts_front[idx[t + 1]], pts_front[idx[t + 2]], -w)
			if back_cap:
				tri(pts_back[idx[t]], pts_back[idx[t + 1]], pts_back[idx[t + 2]], w)
	var ccw := _signed_area(poly2) > 0.0
	for i in n:
		var a := poly2[i]
		var b := poly2[(i + 1) % n]
		var e := b - a
		if e.length_squared() < 1e-10:
			continue
		var n2 := Vector2(e.y, -e.x) if ccw else Vector2(-e.y, e.x)
		var n3 := (u * n2.x + v * n2.y).normalized()
		quad(pts_front[i], pts_front[(i + 1) % n], pts_back[(i + 1) % n], pts_back[i], n3)


## 旋转体：profile 为 (半径, 高度) 序列（自下而上），sides 为边数（低边数 = 多面体风格）。
func lathe(profile: PackedVector2Array, center: Vector3, sides: int, angle0: float = 0.0,
		cap_bottom := false) -> void:
	var rings: Array[PackedVector3Array] = []
	for p in profile:
		var ring := PackedVector3Array()
		for k in sides:
			var a := angle0 + TAU * k / sides
			ring.append(center + Vector3(cos(a) * p.x, p.y, sin(a) * p.x))
		rings.append(ring)
	for j in range(profile.size() - 1):
		for k in sides:
			var k2 := (k + 1) % sides
			var a := rings[j][k]
			var b := rings[j][k2]
			var c := rings[j + 1][k2]
			var d := rings[j + 1][k]
			var mid := (a + b + c + d) * 0.25
			var nrm := (b - a).cross(d - a)
			if nrm.length_squared() < 1e-12:
				nrm = (c - b).cross(d - b)
			nrm = nrm.normalized()
			var outward := Vector3(mid.x - center.x, 0.0, mid.z - center.z)
			if nrm.dot(outward) < 0.0 and outward.length_squared() > 1e-8:
				nrm = -nrm
			if profile[j].x < 1e-5:
				tri(a, c, d, nrm)
			elif profile[j + 1].x < 1e-5:
				tri(a, b, c, nrm)
			else:
				quad(a, b, c, d, nrm)
	if cap_bottom and profile[0].x > 1e-5:
		var ring0 := rings[0]
		var c0 := center + Vector3(0.0, profile[0].y, 0.0)
		for k in sides:
			tri(c0, ring0[k], ring0[(k + 1) % sides], Vector3.DOWN)
	var last := profile.size() - 1
	if profile[last].x > 1e-5:
		var ringn := rings[last]
		var cn := center + Vector3(0.0, profile[last].y, 0.0)
		for k in sides:
			tri(cn, ringn[k], ringn[(k + 1) % sides], Vector3.UP)


## 贴在面上的平面多边形（窗、图案等），沿法线略微偏移避免深度冲突。
func decal(poly2: PackedVector2Array, origin: Vector3, u: Vector3, v: Vector3, n: Vector3,
		offset: float = 0.004) -> void:
	var pts := PackedVector3Array()
	for p in poly2:
		pts.append(origin + n * offset + u * p.x + v * p.y)
	var idx := Geometry2D.triangulate_polygon(poly2)
	for t in range(0, idx.size(), 3):
		tri(pts[idx[t]], pts[idx[t + 1]], pts[idx[t + 2]], n)


# ---------------------------------------------------------------------------
# 常用 2D 轮廓
# ---------------------------------------------------------------------------

## 拱形（矩形 + 顶部半圆），底边中心为原点。
static func arch_shape(width: float, height: float, segs: int = 8) -> PackedVector2Array:
	var r := width * 0.5
	var pts := PackedVector2Array()
	pts.append(Vector2(-r, 0.0))
	pts.append(Vector2(r, 0.0))
	var spring := maxf(height - r, 0.0)
	for i in range(segs + 1):
		var a := PI * i / segs
		pts.append(Vector2(cos(a) * r, spring + sin(a) * r))
	return _dedupe(pts)


## 尖拱（哥特/伊斯兰式），底边中心为原点。
static func pointed_arch_shape(width: float, height: float, segs: int = 6) -> PackedVector2Array:
	# 两段圆弧，圆心分别向对侧偏移，交于顶点形成尖角
	var r := width * 0.5
	var big_r := width * 0.85
	var cx := r - big_r
	var theta_max := acos((big_r - r) / big_r)
	var rise := big_r * sin(theta_max)
	var spring := maxf(height - rise, 0.0)
	var pts := PackedVector2Array()
	pts.append(Vector2(-r, 0.0))
	pts.append(Vector2(r, 0.0))
	for i in range(segs + 1):
		var th := theta_max * i / segs
		pts.append(Vector2(cx + big_r * cos(th), spring + big_r * sin(th)))
	for i in range(segs - 1, -1, -1):
		var th := theta_max * i / segs
		pts.append(Vector2(-(cx + big_r * cos(th)), spring + big_r * sin(th)))
	return _dedupe(pts)


static func rect_shape(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])


static func _signed_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		a += p[i].x * q.y - q.x * p[i].y
	return a * 0.5


static func _dedupe(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > 1e-8:
			out.append(p)
	if out.size() > 2 and out[0].distance_squared_to(out[out.size() - 1]) < 1e-8:
		out.remove_at(out.size() - 1)
	return out
