class_name MonumentBuilder
extends RefCounted
## 程序化建筑：把关卡网格自动"长成"一座浮空庭院。
##
## 输入关卡 + 主题 + 种子，输出：
##   - 一个合并后的静态网格（台基、墙、拱廊、塔楼、屋顶、窗、台阶……按材质分 surface）
##   - AO 高度图（写入全局 shader 参数）
##   - 需要单独动画的装饰节点（水、树等）
## 遮挡规则：任何高出地面的装饰都要经过 _occludes_play() 检查，不得挡住可玩格子。

const SLAB_DEPTH := 0.55       # 地面到台基底部
const CORNICE_H := 0.14        # 台基底部的浅色檐口
const DEPTH := 9.5             # 拱廊向下延伸的深度（消失在雾里）
const WALL_LOW := 0.5
const WALL_HIGH := 1.2
const CAP_H := 0.09
const CAP_OVER := 0.045
const AO_RES := 8              # AO 高度图每格像素数
const AO_MARGIN := 3           # AO 高度图四周留白（格）

const ROOF_STYLE := {
	"dawn": "onion", "garden": "pyramid", "dusk": "spire", "lavender": "pagoda", "night": "dome",
}

var level: LevelData
var theme: Dictionary
var theme_id := "dawn"
var mats: ThemePalette.MaterialLib
var rng := RandomNumberGenerator.new()

var kits := {}                 # 材质键 -> MeshKit
var wall_h := {}               # Vector2i -> 墙高
var top_h := {}                # Vector2i -> 该格最高点（AO 用）
var towers := {}               # Vector2i -> 塔高
var water_cells := {}          # Vector2i -> 出水方向（Vector2i）
var bounds := AABB()

## 需要动画的装饰节点
var water_nodes: Array[MeshInstance3D] = []
var tree_nodes: Array[Node3D] = []
var stairs_node: MeshInstance3D   ## 通向云海的台阶（通关时升起）
## 独立于静态网格的装饰节点（树、水、台阶）：记录入场延迟与基准高度，
## 由 World.set_build 按与 shader 相同的曲线一起升起 / 沉下
var anim_nodes: Array[Node3D] = []
var _stair_kit: MeshKit
var _stairs_delay := 0.0

const WATER_SHADER := preload("res://shaders/water.gdshader")

var _center := Vector2.ZERO
var _max_dist := 1.0


func _init(lvl: LevelData, material_lib: ThemePalette.MaterialLib) -> void:
	level = lvl
	theme_id = lvl.theme
	theme = ThemePalette.get_theme(lvl.theme)
	mats = material_lib
	rng.seed = lvl.decor_seed


func kit(key: String) -> MeshKit:
	if not kits.has(key):
		kits[key] = MeshKit.new()
	return kits[key]


## 构建并返回建筑根节点。
func build() -> Node3D:
	var root := Node3D.new()
	root.name = "Monument"
	_compute_center()
	_compute_wall_heights()
	_select_towers()
	_select_water()
	_build_slab_and_floor()
	_build_walls()
	_build_cornice()
	_build_arcades()
	for p: Vector2i in towers:
		_build_tower(p, towers[p])
	_build_stairs()
	_build_water(root)
	_build_trees(root)

	if _stair_kit and not _stair_kit.is_empty():
		var sm := ArrayMesh.new()
		_stair_kit.commit_to(sm, mats.get_mat("stair"))
		stairs_node = MeshInstance3D.new()
		stairs_node.name = "Stairs"
		stairs_node.mesh = sm
		root.add_child(stairs_node)
		_register_anim(stairs_node, _stairs_delay)
	var mesh := ArrayMesh.new()
	for key in kits:
		(kits[key] as MeshKit).commit_to(mesh, mats.get_mat(key))
	var mi := MeshInstance3D.new()
	mi.name = "Static"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mi)
	bounds = mesh.get_aabb()
	return root


# ---------------------------------------------------------------------------
# 网格分析
# ---------------------------------------------------------------------------

func _solid(p: Vector2i) -> bool:
	return level.get_cell(p) != LevelData.Cell.VOID


func _is_play(p: Vector2i) -> bool:
	return level.get_cell(p) == LevelData.Cell.FLOOR


## 高为 h 的物体放在 cell 上，是否会遮挡可玩格。
## 判定方式：从可玩格中心、离地 EYE_H 高处（约等于石箱底部）朝相机方向发出视线，
## 若视线在升到 h 之前进入物体所在的方格，则视为遮挡。相机角度取自 World。
const EYE_H := 0.2


## half 为物体占地的半宽（塔楼含屋顶外挑约 0.75）。每个候选格从中心与左右两侧各发一条视线。
func _occludes_play(cell: Vector2i, h: float, half := 0.55) -> bool:
	if h <= EYE_H:
		return false
	var pitch := deg_to_rad(absf(World.pitch_deg))
	var yaw := deg_to_rad(World.yaw_deg)
	# 水平面上朝向相机的方向（网格坐标：x = 列，y = 行）
	var to_cam := Vector2(sin(yaw), cos(yaw))
	var side := Vector2(to_cam.y, -to_cam.x) * 0.3
	var reach := (h - EYE_H) / tan(pitch)
	var span := int(ceil(reach + half)) + 1
	for dy in range(-span, 1):
		for dx in range(-span, span + 1):
			var q := cell + Vector2i(dx, dy)
			if q == cell or not _is_play(q):
				continue
			for o in [Vector2.ZERO, side, -side]:
				if _ray_hits_square(Vector2(q) + o, to_cam, reach, Vector2(cell), half):
					return true
	return false


## 从 origin 沿 dir 前进不超过 length，是否进入以 center 为中心、半宽为 half 的方格。
static func _ray_hits_square(origin: Vector2, dir: Vector2, length: float, center: Vector2, half: float) -> bool:
	var t0 := 0.0
	var t1 := length
	for axis in 2:
		var o := origin[axis] - center[axis]
		var d := dir[axis]
		if absf(d) < 1e-6:
			if absf(o) > half:
				return false
			continue
		var a := (-half - o) / d
		var b := (half - o) / d
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	return t0 <= t1


func _compute_center() -> void:
	var sum := Vector2.ZERO
	var n := 0
	for y in level.height:
		for x in level.width:
			if _solid(Vector2i(x, y)):
				sum += Vector2(x, y)
				n += 1
	_center = sum / maxf(n, 1)
	_max_dist = 1.0
	for y in level.height:
		for x in level.width:
			if _solid(Vector2i(x, y)):
				_max_dist = maxf(_max_dist, Vector2(x, y).distance_to(_center))


## 入场动画延迟：离中心越远越晚升起，带一点随机。
func _delay_for(p: Vector2, jitter := 0.08) -> float:
	var d := p.distance_to(_center) / _max_dist
	return clampf(d * 0.85 + rng.randf() * jitter, 0.0, 1.0)


func _compute_wall_heights() -> void:
	for y in level.height:
		for x in level.width:
			var p := Vector2i(x, y)
			if not level.is_wall(p):
				continue
			var h := WALL_HIGH
			if _occludes_play(p, WALL_HIGH):
				h = WALL_LOW
			wall_h[p] = h
			top_h[p] = h


# ---------------------------------------------------------------------------
# 台基与地面
# ---------------------------------------------------------------------------

func _build_slab_and_floor() -> void:
	var fk := kit("floor")
	var bk := kit("base")
	for y in level.height:
		for x in level.width:
			var p := Vector2i(x, y)
			if not _is_play(p):
				continue
			var cx := float(x)
			var cz := float(y)
			fk.uv2 = Vector2(_delay_for(Vector2(p)), 1.0)
			fk.color = Color.WHITE
			fk.quad(Vector3(cx - 0.5, 0, cz - 0.5), Vector3(cx + 0.5, 0, cz - 0.5),
				Vector3(cx + 0.5, 0, cz + 0.5), Vector3(cx - 0.5, 0, cz + 0.5), Vector3.UP)
			top_h[p] = 0.0
			# 地板格紧邻虚空时补台基侧面
			bk.uv2 = fk.uv2
			for d in SokobanState.DIRS:
				if _solid(p + d):
					continue
				_side_face(bk, p, d, -SLAB_DEPTH, 0.0)


## 在格子 p 的 d 方向一侧生成竖直面。
func _side_face(k: MeshKit, p: Vector2i, d: Vector2i, y0: float, y1: float) -> void:
	var c := Vector3(p.x, 0, p.y)
	var n := Vector3(d.x, 0, d.y)
	var t := Vector3(-d.y, 0, d.x)  # 沿边方向
	var e := c + n * 0.5
	k.quad(e - t * 0.5 + Vector3(0, y0, 0), e + t * 0.5 + Vector3(0, y0, 0),
		e + t * 0.5 + Vector3(0, y1, 0), e - t * 0.5 + Vector3(0, y1, 0), n)


# ---------------------------------------------------------------------------
# 墙
# ---------------------------------------------------------------------------

func _build_walls() -> void:
	var wk := kit("wall")
	var ck := kit("trim")
	for p: Vector2i in wall_h:
		var h: float = wall_h[p]
		var cx := float(p.x)
		var cz := float(p.y)
		var delay := _delay_for(Vector2(p))
		wk.uv2 = Vector2(delay, 1.0)
		ck.uv2 = wk.uv2
		# 墙体（向下延伸进台基，外侧面与台基侧面连成一体）
		var faces := MeshKit.FACES_NO_BOTTOM & ~MeshKit.FACE_PY
		wk.box(Vector3(cx - 0.5, -SLAB_DEPTH, cz - 0.5), Vector3(cx + 0.5, h - CAP_H, cz + 0.5), faces)
		if water_cells.has(p):
			continue
		# 压顶：只在不与相邻墙相接的一侧外挑
		var x0 := cx - 0.5 - (CAP_OVER if not _wall_at(p + Vector2i.LEFT, h) else 0.0)
		var x1 := cx + 0.5 + (CAP_OVER if not _wall_at(p + Vector2i.RIGHT, h) else 0.0)
		var z0 := cz - 0.5 - (CAP_OVER if not _wall_at(p + Vector2i.UP, h) else 0.0)
		var z1 := cz + 0.5 + (CAP_OVER if not _wall_at(p + Vector2i.DOWN, h) else 0.0)
		ck.box(Vector3(x0, h - CAP_H, z0), Vector3(x1, h, z1), MeshKit.FACES_ALL)


func _wall_at(p: Vector2i, h: float) -> bool:
	return wall_h.has(p) and is_equal_approx(wall_h[p], h)


# ---------------------------------------------------------------------------
# 檐口与拱廊（台基下方）
# ---------------------------------------------------------------------------

## 找出所有外轮廓边，按方向和所在直线分组成连续段。
## 返回 [{dir: Vector2i, cells: [Vector2i...]}]
func _outline_runs() -> Array:
	var runs: Array = []
	for d in SokobanState.DIRS:
		var t := Vector2i(absi(d.y), absi(d.x))  # 沿边方向（正向）
		var visited := {}
		for y in level.height:
			for x in level.width:
				var p := Vector2i(x, y)
				if visited.has(p) or not _solid(p) or _solid(p + d):
					continue
				# 回退到该段起点
				var s := p
				while _solid(s - t) and not _solid(s - t + d):
					s -= t
				var cells: Array[Vector2i] = []
				var q := s
				while _solid(q) and not _solid(q + d):
					cells.append(q)
					visited[q] = true
					q += t
				runs.append({"dir": d, "cells": cells})
	return runs


func _build_cornice() -> void:
	var tk := kit("trim")
	for run in _outline_runs():
		var d: Vector2i = run["dir"]
		var cells: Array = run["cells"]
		var n := Vector3(d.x, 0, d.y)
		for p: Vector2i in cells:
			tk.uv2 = Vector2(_delay_for(Vector2(p)), 1.0)
			var c := Vector3(p.x, 0, p.y) + n * 0.5
			var t := Vector3(absf(n.z), 0, absf(n.x))
			var y0 := -SLAB_DEPTH - CORNICE_H
			var y1 := -SLAB_DEPTH
			var mn := c - t * 0.56 - n * 0.02 + Vector3(0, y0, 0)
			var mx := c + t * 0.56 + n * 0.06 + Vector3(0, y1, 0)
			# 顺着边方向时，min/max 需要按轴排序
			tk.box(Vector3(minf(mn.x, mx.x), y0, minf(mn.z, mx.z)), Vector3(maxf(mn.x, mx.x), y1, maxf(mn.z, mx.z)), MeshKit.FACES_ALL)


func _build_arcades() -> void:
	var ak := kit("arcade")
	const THICK := 0.4
	var top := -SLAB_DEPTH - CORNICE_H
	for run in _outline_runs():
		var d: Vector2i = run["dir"]
		var cells: Array = run["cells"]
		var n := Vector3(d.x, 0, d.y)
		var t := Vector3(absf(n.z), 0, absf(n.x))
		var first: Vector2i = cells[0]
		var origin := Vector3(first.x, 0, first.y) + n * 0.5 - t * 0.5
		var length := float(cells.size())
		ak.uv2 = Vector2(_delay_for(Vector2(first) + Vector2(t.x, t.z) * length * 0.5), 1.0)
		# 轮廓：顶边 + 底部若干拱形开口
		var poly := PackedVector2Array()
		poly.append(Vector2(0.0, -DEPTH))
		var bays := _split_bays(cells.size())
		var u := 0.0
		for bay in bays:
			var pier := 0.32 if bay >= 2 else 0.22
			var a0 := u + pier
			var a1 := u + bay - pier
			var r := (a1 - a0) * 0.5
			var apex := top - 0.42
			var spring := apex - r
			poly.append(Vector2(a0, -DEPTH))
			for i in range(13):
				var ang := PI - PI * i / 12.0
				poly.append(Vector2(a0 + r + cos(ang) * r, spring + sin(ang) * r))
			poly.append(Vector2(a1, -DEPTH))
			u += bay
		poly.append(Vector2(length, -DEPTH))
		poly.append(Vector2(length, top))
		poly.append(Vector2(0.0, top))
		poly = MeshKit._dedupe(poly)
		ak.extrude(poly, origin, t, Vector3.UP, -n, THICK)


## 把长度为 n 的边分成若干拱跨（每跨 2 格，余数并入最后一跨）。
func _split_bays(n: int) -> Array[int]:
	var bays: Array[int] = []
	if n <= 2:
		bays.append(n)
		return bays
	var rest := n
	while rest > 3:
		bays.append(2)
		rest -= 2
	bays.append(rest)
	return bays


# ---------------------------------------------------------------------------
# 塔楼
# ---------------------------------------------------------------------------

## 塔楼放在外轮廓的凸角上：优先最远端的几个角，彼此保持距离，且不遮挡可玩格。
func _select_towers() -> void:
	var candidates: Array[Vector2i] = []
	for p: Vector2i in wall_h:
		var void_x := (not _solid(p + Vector2i.LEFT)) or (not _solid(p + Vector2i.RIGHT))
		var void_z := (not _solid(p + Vector2i.UP)) or (not _solid(p + Vector2i.DOWN))
		if void_x and void_z:
			candidates.append(p)
	# 离中心越远越优先（菱形的几个尖角）
	candidates.sort_custom(func(a, b): return Vector2(a).distance_squared_to(_center) > Vector2(b).distance_squared_to(_center))
	for p in candidates:
		if towers.size() >= 4:
			break
		var too_close := false
		for t in towers:
			if absi(t.x - p.x) + absi(t.y - p.y) < 4:
				too_close = true
				break
		if too_close:
			continue
		var h := rng.randf_range(2.3, 3.0)
		# 计入屋顶高度（约 1.1）与屋顶外挑
		if _occludes_play(p, h + 1.1, 0.78):
			continue
		towers[p] = h


func _build_tower(p: Vector2i, h: float) -> void:
	var tk := kit("tower")
	var trim := kit("trim")
	var delay := _delay_for(Vector2(p), 0.04)
	tk.uv2 = Vector2(delay, 1.0)
	trim.uv2 = tk.uv2
	var c := Vector3(p.x, 0, p.y)
	const HALF := 0.52
	tk.box(c + Vector3(-HALF, -SLAB_DEPTH, -HALF), c + Vector3(HALF, h, HALF))
	# 顶部檐口
	trim.box(c + Vector3(-HALF - 0.06, h, -HALF - 0.06), c + Vector3(HALF + 0.06, h + 0.12, HALF + 0.06), MeshKit.FACES_ALL)
	top_h[p] = h + 0.12
	# 窗（两个可见面）
	var wk := kit("window")
	wk.uv2 = tk.uv2
	for side in [Vector3.RIGHT, Vector3.BACK]:
		var n: Vector3 = side
		var u := Vector3.BACK if n == Vector3.RIGHT else Vector3.RIGHT
		var face := c + n * HALF
		var shape := MeshKit.pointed_arch_shape(0.2, 0.46)
		wk.decal(shape, face + Vector3(0, h - 0.85, 0), u, Vector3.UP, n)
		if h > 2.6:
			wk.decal(MeshKit.pointed_arch_shape(0.16, 0.34), face + Vector3(0, h - 1.55, 0), u, Vector3.UP, n)
	_build_roof(c + Vector3(0, h + 0.12, 0), HALF + 0.1)


func _build_roof(base: Vector3, half: float) -> void:
	var rk := kit("roof")
	rk.uv2 = kit("tower").uv2
	var style: String = ROOF_STYLE.get(theme_id, "pyramid")
	match style:
		"onion":
			var r := half * 0.95
			rk.lathe(PackedVector2Array([
				Vector2(r * 0.85, 0.0), Vector2(r * 1.0, 0.16), Vector2(r * 0.95, 0.36),
				Vector2(r * 0.68, 0.58), Vector2(r * 0.32, 0.8), Vector2(r * 0.1, 0.96), Vector2(0.0, 1.1),
			]), base, 8, PI / 8.0)
			_finial(base + Vector3(0, 1.1, 0))
		"pyramid":
			rk.lathe(PackedVector2Array([Vector2(half * 1.414, 0.0), Vector2(0.0, 0.85)]), base, 4, PI / 4.0, true)
			_finial(base + Vector3(0, 0.85, 0))
		"spire":
			rk.lathe(PackedVector2Array([Vector2(half * 1.05, 0.0), Vector2(0.0, 1.5)]), base, 8, PI / 8.0, true)
		"pagoda":
			rk.lathe(PackedVector2Array([
				Vector2(half * 1.75, 0.0), Vector2(half * 1.45, 0.14), Vector2(half * 0.8, 0.42), Vector2(0.0, 0.8),
			]), base, 4, PI / 4.0, true)
			_finial(base + Vector3(0, 0.8, 0))
		_:
			var r2 := half * 1.0
			var prof := PackedVector2Array()
			for i in range(7):
				var a := PI * 0.5 * i / 6.0
				prof.append(Vector2(cos(a) * r2, sin(a) * r2 * 0.95))
			rk.lathe(prof, base, 8, PI / 8.0)
			_finial(base + Vector3(0, r2 * 0.95, 0))


func _finial(at: Vector3) -> void:
	var fk := kit("trim")
	fk.uv2 = kit("tower").uv2
	fk.lathe(PackedVector2Array([Vector2(0.05, 0.0), Vector2(0.09, 0.08), Vector2(0.05, 0.16), Vector2(0.0, 0.3)]), at, 4, PI / 4.0)


# ---------------------------------------------------------------------------
# 水渠与瀑布
# ---------------------------------------------------------------------------

## 在可见外侧（+X/+Z）的直墙中段选 1~2 处水渠，水越过墙沿形成瀑布。
func _select_water() -> void:
	var cands: Array = []
	for p: Vector2i in wall_h:
		if towers.has(p):
			continue
		# 只放在正面（+Z）：新视角下右侧面很窄，瀑布会被压扁
		for d in [Vector2i.DOWN]:
			if _solid(p + d):
				continue
			var t := Vector2i(absi(d.y), absi(d.x))
			if not (wall_h.has(p + t) and wall_h.has(p - t)):
				continue
			if _solid(p + t + d) or _solid(p - t + d):
				continue
			var near_tower := false
			for tp: Vector2i in towers:
				if Vector2(tp - p).length() < 2.5:
					near_tower = true
			if not near_tower:
				cands.append([p, d])
	_shuffle(cands)
	var want := 2 if level.floor_count() > 30 else 1
	for c in cands:
		if water_cells.size() >= want:
			break
		var ok := true
		for q: Vector2i in water_cells:
			if absi(q.x - c[0].x) + absi(q.y - c[0].y) < 4:
				ok = false
		if ok:
			water_cells[c[0]] = c[1]


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## 按两个对角点生成长方体（自动排序坐标）。
func _obox(k: MeshKit, a: Vector3, b: Vector3, faces: int = MeshKit.FACES_ALL) -> void:
	k.box(Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z)),
		Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z)), faces)


static func _uv_quad(pts: Array, uvs: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_normal(Vector3.UP)
		st.set_uv(uvs[i])
		st.add_vertex(pts[i])
	return st.commit()


func _build_water(root: Node3D) -> void:
	if water_cells.is_empty():
		return
	var surf_mat := ShaderMaterial.new()
	surf_mat.shader = WATER_SHADER
	surf_mat.set_shader_parameter("water_color", theme["water"])
	surf_mat.set_shader_parameter("mode", 0)
	var fall_mat := ShaderMaterial.new()
	fall_mat.shader = WATER_SHADER
	fall_mat.set_shader_parameter("water_color", theme["water"])
	fall_mat.set_shader_parameter("mode", 1)
	var trim := kit("trim")
	var spout := kit("tower")
	var win := kit("window")
	for p: Vector2i in water_cells:
		var d: Vector2i = water_cells[p]
		var h: float = wall_h[p]
		var n := Vector3(d.x, 0, d.y)
		var t := Vector3(absf(n.z), 0, absf(n.x))
		var c := Vector3(p.x, 0, p.y)
		var delay := _delay_for(Vector2(p))
		for k in [trim, spout, win]:
			k.uv2 = Vector2(delay, 1.0)
		# 两侧渠沿
		for side in [-1.0, 1.0]:
			_obox(trim, c - n * 0.5 + t * side * 0.5 + Vector3(0, h - CAP_H, 0),
				c + n * (0.5 + CAP_OVER) + t * side * 0.33 + Vector3(0, h, 0))
		# 内端泉眼
		_obox(spout, c - n * 0.5 - t * 0.36 + Vector3(0, h - CAP_H, 0), c - n * 0.26 + t * 0.36 + Vector3(0, h + 0.26, 0))
		_obox(trim, c - n * 0.53 - t * 0.4 + Vector3(0, h + 0.26, 0), c - n * 0.23 + t * 0.4 + Vector3(0, h + 0.32, 0))
		win.decal(MeshKit.arch_shape(0.2, 0.22), c - n * 0.26 + Vector3(0, h - 0.02, 0), t, Vector3.UP, n)
		# 水面
		var y := h - 0.035
		var a0 := c - n * 0.26 - t * 0.33 + Vector3(0, y, 0)
		var a1 := c - n * 0.26 + t * 0.33 + Vector3(0, y, 0)
		var b1 := c + n * 0.56 + t * 0.33 + Vector3(0, y, 0)
		var b0 := c + n * 0.56 - t * 0.33 + Vector3(0, y, 0)
		var surf := MeshInstance3D.new()
		surf.mesh = _uv_quad([a0, a1, b1, b0], [Vector2(0, 0), Vector2(1, 0), Vector2(1, 0.82), Vector2(0, 0.82)])
		surf.material_override = surf_mat
		root.add_child(surf)
		water_nodes.append(surf)
		_register_anim(surf, delay)
		# 瀑布（含翻越墙沿的弧度）
		var top := c + n * 0.56 + Vector3(0, y, 0)
		var lip := c + n * 0.64 + Vector3(0, y - 0.1, 0)
		var bottom := c + n * 0.66 + Vector3(0, -DEPTH, 0)
		var fall_len := y + DEPTH
		var w := 0.31
		var lip_mi := MeshInstance3D.new()
		lip_mi.mesh = _uv_quad([top - t * w, top + t * w, lip + t * w, lip - t * w],
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, 0.12), Vector2(0, 0.12)])
		lip_mi.material_override = fall_mat
		root.add_child(lip_mi)
		var fall := MeshInstance3D.new()
		fall.mesh = _uv_quad([lip - t * w, lip + t * w, bottom + t * w, bottom - t * w],
			[Vector2(0, 0.12), Vector2(1, 0.12), Vector2(1, fall_len), Vector2(0, fall_len)])
		fall.material_override = fall_mat
		root.add_child(fall)
		water_nodes.append(lip_mi)
		water_nodes.append(fall)
		_register_anim(lip_mi, delay)
		_register_anim(fall, delay)


# ---------------------------------------------------------------------------
# 台阶
# ---------------------------------------------------------------------------

## 在一段较长的可见外侧边上，从台基的小门沿外墙向下延伸一段台阶，没入云海。
func _build_stairs() -> void:
	var best: Dictionary = {}
	for run in _outline_runs():
		var run_dir: Vector2i = run["dir"]
		if run_dir != Vector2i.DOWN:
			continue
		var run_cells: Array = run["cells"]
		if run_cells.size() < 4:
			continue
		var blocked := false
		for c: Vector2i in run_cells:
			if water_cells.has(c):
				blocked = true
		if blocked:
			continue
		if best.is_empty() or run_cells.size() > (best["cells"] as Array).size():
			best = run
	if best.is_empty():
		return
	var d: Vector2i = best["dir"]
	var cells: Array = best["cells"]
	var n := Vector3(d.x, 0, d.y)
	var t := Vector3(absf(n.z), 0, absf(n.x))
	var first: Vector2i = cells[0]
	var origin := Vector3(first.x, 0, first.y) + n * 0.5 - t * 0.5
	var length := float(cells.size())
	var y_top := -SLAB_DEPTH - CORNICE_H - 0.62
	var u0 := 0.7
	const RISE := 0.17
	const RUN := 0.26
	var steps := int(floor((length - 0.15 - u0 - 0.3) / RUN))
	steps = clampi(steps, 4, 14)
	var poly := PackedVector2Array()
	poly.append(Vector2(u0 - 0.38, y_top))
	var u := u0 + 0.3
	var yy := y_top
	for i in steps:
		poly.append(Vector2(u, yy))
		yy -= RISE
		poly.append(Vector2(u, yy))
		u += RUN
	poly.append(Vector2(u, yy))
	poly.append(Vector2(u, yy - 0.42))
	poly.append(Vector2(u0 + 0.3, y_top - 0.62))
	poly.append(Vector2(u0 - 0.38, y_top - 0.62))
	# 台阶单独成网格：游戏中沉在云下，通关时升起
	_stairs_delay = _delay_for(Vector2(first))
	_stair_kit = MeshKit.new()
	_stair_kit.uv2 = Vector2(0.0, 0.0)
	_stair_kit.extrude(MeshKit._dedupe(poly), origin, t, Vector3.UP, n, 0.58)
	# 台阶顶端的小门
	var win := kit("window")
	win.uv2 = Vector2(_delay_for(Vector2(first)), 1.0)
	win.decal(MeshKit.pointed_arch_shape(0.38, 0.6), origin + t * u0 + Vector3(0, y_top, 0), t, Vector3.UP, n)


# ---------------------------------------------------------------------------
# 树
# ---------------------------------------------------------------------------

## 在高墙顶上放 1~2 棵盆栽樱花树（不遮挡可玩格，远离塔楼与水渠）。
func _build_trees(root: Node3D) -> void:
	var cands: Array[Vector2i] = []
	for p: Vector2i in wall_h:
		if towers.has(p) or water_cells.has(p) or wall_h[p] < WALL_HIGH - 0.01:
			continue
		var near := false
		for tp: Vector2i in towers:
			if absi(tp.x - p.x) + absi(tp.y - p.y) < 2:
				near = true
		for wp: Vector2i in water_cells:
			if absi(wp.x - p.x) + absi(wp.y - p.y) < 2:
				near = true
		if near or _occludes_play(p, WALL_HIGH + 1.4, 0.6):
			continue
		cands.append(p)
	var arr: Array = cands
	_shuffle(arr)
	var placed: Array[Vector2i] = []
	for p: Vector2i in arr:
		if placed.size() >= 2:
			break
		var ok := true
		for q in placed:
			if absi(q.x - p.x) + absi(q.y - p.y) < 4:
				ok = false
		if ok:
			placed.append(p)
			_build_tree(root, p)


func _build_tree(root: Node3D, p: Vector2i) -> void:
	var h: float = wall_h[p]
	var c := Vector3(p.x, h, p.y)
	var delay := _delay_for(Vector2(p))
	var pk := kit("planter")
	var tk := kit("trunk")
	pk.uv2 = Vector2(delay, 1.0)
	tk.uv2 = pk.uv2
	pk.box(c + Vector3(-0.28, 0, -0.28), c + Vector3(0.28, 0.22, 0.28))
	tk.box(c + Vector3(-0.22, 0.2, -0.22), c + Vector3(0.22, 0.225, 0.22), MeshKit.FACE_PY)
	tk.lathe(PackedVector2Array([Vector2(0.055, 0.2), Vector2(0.04, 0.62), Vector2(0.028, 0.82)]), c, 5, 0.3)
	tk.box(c + Vector3(-0.2, 0.55, -0.02), c + Vector3(0.0, 0.58, 0.02), MeshKit.FACES_ALL)
	tk.box(c + Vector3(0.0, 0.66, -0.02), c + Vector3(0.18, 0.69, 0.02), MeshKit.FACES_ALL)
	# 树冠：单独节点，用于风吹摆动与开花动画
	var crown := Node3D.new()
	crown.name = "Tree"
	crown.position = c + Vector3(0, 0.45, 0)
	var fk := MeshKit.new()
	fk.uv2 = Vector2(delay, 1.0)
	var blobs := [
		[Vector3(0, 0.45, 0), 0.36], [Vector3(0.24, 0.36, 0.08), 0.26], [Vector3(-0.22, 0.4, -0.1), 0.25],
		[Vector3(0.04, 0.72, -0.04), 0.22], [Vector3(-0.08, 0.3, 0.22), 0.2],
	]
	for b in blobs:
		var r: float = b[1] * rng.randf_range(0.9, 1.1)
		var prof := PackedVector2Array()
		for i in range(6):
			var a := PI * i / 5.0
			prof.append(Vector2(sin(a) * r, -cos(a) * r * 0.88))
		fk.lathe(prof, b[0], 7, rng.randf() * TAU)
	var mesh := ArrayMesh.new()
	fk.commit_to(mesh, mats.get_mat("foliage"))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	crown.add_child(mi)
	root.add_child(crown)
	tree_nodes.append(crown)
	_register_anim(crown, delay)
	top_h[p] = h + 0.3


func _register_anim(n: Node3D, delay: float) -> void:
	n.set_meta("delay", delay)
	n.set_meta("base_y", n.position.y)
	anim_nodes.append(n)


# ---------------------------------------------------------------------------
# AO 高度图
# ---------------------------------------------------------------------------

## 生成 AO 高度图并写入全局 shader 参数。
func build_ao_map() -> void:
	var w := (level.width + AO_MARGIN * 2) * AO_RES
	var h := (level.height + AO_MARGIN * 2) * AO_RES
	var data := PackedFloat32Array()
	data.resize(w * h)
	data.fill(0.0)
	for p: Vector2i in top_h:
		var v: float = top_h[p]
		var px0 := (p.x + AO_MARGIN) * AO_RES
		var py0 := (p.y + AO_MARGIN) * AO_RES
		for yy in AO_RES:
			for xx in AO_RES:
				data[(py0 + yy) * w + px0 + xx] = v
	data = _blur(data, w, h, int(AO_RES * 0.7))
	data = _blur(data, w, h, int(AO_RES * 0.5))
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RF, data.to_byte_array())
	var tex := ImageTexture.create_from_image(img)
	RenderingServer.global_shader_parameter_set("mv_ao_map", tex)
	# 像素中心对齐：格子 (0,0) 的中心位于世界 (0,0)
	var origin := Vector2(-AO_MARGIN - 0.5, -AO_MARGIN - 0.5)
	RenderingServer.global_shader_parameter_set("mv_ao_rect",
		Vector4(origin.x, origin.y, level.width + AO_MARGIN * 2, level.height + AO_MARGIN * 2))


static func _blur(src: PackedFloat32Array, w: int, h: int, r: int) -> PackedFloat32Array:
	if r <= 0:
		return src
	var tmp := PackedFloat32Array()
	tmp.resize(w * h)
	var out := PackedFloat32Array()
	out.resize(w * h)
	var inv := 1.0 / (2 * r + 1)
	for y in h:
		var acc := 0.0
		for x in range(-r, r + 1):
			acc += src[y * w + clampi(x, 0, w - 1)]
		for x in w:
			tmp[y * w + x] = acc * inv
			acc += src[y * w + clampi(x + r + 1, 0, w - 1)] - src[y * w + clampi(x - r, 0, w - 1)]
	for x in w:
		var acc := 0.0
		for y in range(-r, r + 1):
			acc += tmp[clampi(y, 0, h - 1) * w + x]
		for y in h:
			out[y * w + x] = acc * inv
			acc += tmp[clampi(y + r + 1, 0, h - 1) * w + x] - tmp[clampi(y - r, 0, h - 1) * w + x]
	return out
