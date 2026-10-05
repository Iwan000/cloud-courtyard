class_name Props
extends RefCounted
## 可移动物件的网格：箱子、目标地砖。

const BOX_SIZE := 0.78


## 石箱：箱身 + 各面内嵌浅色面板 + 菱形符号（入位时符号发光）。
static func make_box_mesh(mats: ThemePalette.MaterialLib) -> ArrayMesh:
	var body := MeshKit.new()
	var panel := MeshKit.new()
	var glyph := MeshKit.new()
	for k in [body, panel, glyph]:
		k.uv2 = Vector2(0, 0)
	var s := BOX_SIZE
	var h := s * 0.5
	body.box(Vector3(-h, 0, -h), Vector3(h, s, h))
	var panel_shape := MeshKit.rect_shape(-s * 0.37, -s * 0.37, s * 0.37, s * 0.37)
	var glyph_shape := PackedVector2Array([
		Vector2(0, -s * 0.25), Vector2(s * 0.25, 0), Vector2(0, s * 0.25), Vector2(-s * 0.25, 0)])
	var glyph_hole := PackedVector2Array([
		Vector2(0, -s * 0.13), Vector2(s * 0.13, 0), Vector2(0, s * 0.13), Vector2(-s * 0.13, 0)])
	# (中心, u, v, 法线)
	var faces := [
		[Vector3(0, s, 0), Vector3.RIGHT, Vector3.BACK, Vector3.UP],
		[Vector3(h, h, 0), Vector3.BACK, Vector3.UP, Vector3.RIGHT],
		[Vector3(0, h, h), Vector3.RIGHT, Vector3.UP, Vector3.BACK],
		[Vector3(-h, h, 0), Vector3.BACK, Vector3.UP, Vector3.LEFT],
		[Vector3(0, h, -h), Vector3.RIGHT, Vector3.UP, Vector3.FORWARD],
	]
	for f in faces:
		panel.decal(panel_shape, f[0], f[1], f[2], f[3], 0.003)
		glyph.decal(glyph_shape, f[0], f[1], f[2], f[3], 0.006)
		panel.decal(glyph_hole, f[0], f[1], f[2], f[3], 0.009)
	var mesh := ArrayMesh.new()
	body.commit_to(mesh, mats.get_mat("box"))
	panel.commit_to(mesh, mats.get_mat("box_panel"))
	glyph.commit_to(mesh, mats.get_mat("box_glyph"))
	return mesh


## 目标地砖：带 UV 的方形面片，图案由 shader（pattern 3）绘制。
static func make_target_mesh(mats: ThemePalette.MaterialLib) -> Mesh:
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.94, 0.94)
	plane.material = mats.get_mat("target")
	return plane
