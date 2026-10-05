class_name World
extends Node3D
## 3D 世界根节点：等轴正交相机、只投影的方向光、环境、2D 天空背景、后处理。
## 负责加载关卡的静态建筑；动态物体（箱子、角色）由 BoardView 管理。

const PITCH_DEG := -35.264
const YAW_DEG := 45.0
const CAM_DISTANCE := 30.0
const SKY_SHADER := preload("res://shaders/sky_canvas.gdshader")
const POST_SHADER := preload("res://shaders/post.gdshader")
const CLOUD_SHADER := preload("res://shaders/cloud.gdshader")

var camera: Camera3D
var light: DirectionalLight3D
var env: Environment
var sky_mat: ShaderMaterial
var post_mat: ShaderMaterial
var mats: ThemePalette.MaterialLib
var monument: Node3D
var builder: MonumentBuilder
var level: LevelData
var theme: Dictionary
var decor: Node3D                     ## 云、远景浮岛等氛围装饰
var cloud_mat: ShaderMaterial
var _clouds: Array[Node3D] = []
var _islands: Array[Node3D] = []
var _t := 0.0

## 相机目标与正交尺寸（可被动画驱动）
var cam_target := Vector3.ZERO:
	set(v):
		cam_target = v
		_update_camera()
var cam_size := 12.0:
	set(v):
		cam_size = v
		if camera:
			camera.size = v


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_light()
	_setup_background()
	_setup_post()


func _setup_environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.background_canvas_max_layer = -1
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = true
	env.glow_hdr_threshold = 1.0
	env.glow_intensity = 0.7
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)


func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = cam_size
	camera.near = 0.5
	camera.far = 90.0
	camera.rotation_degrees = Vector3(PITCH_DEG, YAW_DEG, 0.0)
	add_child(camera)
	_update_camera()


func _update_camera() -> void:
	if camera:
		camera.position = cam_target + camera.basis.z * CAM_DISTANCE


func _setup_light() -> void:
	light = DirectionalLight3D.new()
	light.name = "Sun"
	light.light_energy = 1.0
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.directional_shadow_max_distance = 60.0
	light.directional_shadow_fade_start = 1.0
	light.shadow_blur = 1.6
	light.shadow_bias = 0.03
	light.shadow_normal_bias = 0.6
	light.light_angular_distance = 2.0
	add_child(light)
	# 光线方向：从右后上方照来，影子落向屏幕左下
	light.look_at_from_position(Vector3.ZERO, Vector3(-0.42, -1.0, 0.62), Vector3.UP)


func _setup_background() -> void:
	var layer := CanvasLayer.new()
	layer.name = "SkyLayer"
	layer.layer = -10
	add_child(layer)
	var rect := ColorRect.new()
	rect.name = "Sky"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	rect.material = sky_mat
	layer.add_child(rect)


func _setup_post() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PostLayer"
	layer.layer = 5
	add_child(layer)
	var rect := ColorRect.new()
	rect.name = "Post"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_mat = ShaderMaterial.new()
	post_mat.shader = POST_SHADER
	rect.material = post_mat
	layer.add_child(rect)


# ---------------------------------------------------------------------------
# 关卡
# ---------------------------------------------------------------------------

func load_level(lvl: LevelData) -> void:
	level = lvl
	apply_theme(lvl.theme)
	if monument:
		monument.queue_free()
	builder = MonumentBuilder.new(lvl, mats)
	monument = builder.build()
	add_child(monument)
	builder.build_ao_map()
	frame_level()
	_build_atmosphere()


func _process(delta: float) -> void:
	_t += delta
	for i in _islands.size():
		var isl := _islands[i]
		var base_y: float = isl.get_meta("base_y")
		isl.position.y = base_y + sin(_t * 0.35 + i * 1.7) * 0.25
	for c in _clouds:
		var speed: float = c.get_meta("speed")
		var origin: Vector3 = c.get_meta("origin")
		var span: float = c.get_meta("span")
		var off := fposmod(_t * speed + c.get_meta("phase"), span) - span * 0.5
		c.position = origin + camera.basis.x * off
	if builder:
		for i in builder.tree_nodes.size():
			var tr := builder.tree_nodes[i]
			tr.rotation.z = sin(_t * 1.1 + i * 2.0) * 0.035
			tr.rotation.x = sin(_t * 0.8 + i) * 0.025


# ---------------------------------------------------------------------------
# 氛围：云海与远景浮岛
# ---------------------------------------------------------------------------

func _build_atmosphere() -> void:
	if decor:
		decor.queue_free()
	decor = Node3D.new()
	decor.name = "Atmosphere"
	add_child(decor)
	_clouds.clear()
	_islands.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = level.seed * 31 + 7
	_spawn_islands(rng)
	_spawn_clouds(rng)


## 平台最靠近相机的角（地面高度）在屏幕上的纵坐标（相对相机目标）。
func _near_corner_screen_y() -> float:
	var p := Vector3(level.width - 0.5, -0.7, level.height - 0.5)
	return (camera.basis.inverse() * (p - cam_target)).y


## 把屏幕空间坐标（以相机目标为原点，单位为世界尺度）和深度换算为世界坐标。
func _screen_to_world(sx: float, sy: float, depth: float) -> Vector3:
	return cam_target + camera.basis.x * sx + camera.basis.y * sy - camera.basis.z * depth


func _spawn_islands(rng: RandomNumberGenerator) -> void:
	var half_w := cam_size * 0.5 * 16.0 / 9.0
	var slots := [Vector2(-0.8, 0.42), Vector2(-0.96, -0.28), Vector2(0.9, -0.12), Vector2(0.62, -0.66)]
	for i in slots.size():
		var slot: Vector2 = slots[i]
		var w := rng.randi_range(3, 5)
		var h := rng.randi_range(3, 4)
		var lvl := LevelData.create_empty(w, h)
		lvl.theme = level.theme
		lvl.seed = rng.randi()
		for y in h:
			for x in w:
				var edge := x == 0 or y == 0 or x == w - 1 or y == h - 1
				lvl.set_cell(Vector2i(x, y), LevelData.Cell.WALL if edge else LevelData.Cell.FLOOR)
		var b := MonumentBuilder.new(lvl, mats)
		b.is_island = true
		var node := b.build()
		var scale := rng.randf_range(0.3, 0.4)
		node.scale = Vector3.ONE * scale
		var pos := _screen_to_world(slot.x * half_w, slot.y * cam_size * 0.5, rng.randf_range(30.0, 42.0))
		pos -= Vector3(w * 0.5, 0, h * 0.5) * scale
		node.position = pos
		node.set_meta("base_y", pos.y)
		var fade := 0.42 + rng.randf() * 0.1
		# 淡化到其背后的天空颜色，而不是统一的白色
		var sky_t := clampf(0.5 - slot.y * 0.5, 0.0, 1.0)
		var sky_col: Color = Color(theme["sky_top"]).lerp(theme["sky_bottom"], pow(sky_t, 0.85))
		for child in node.get_children():
			if child is GeometryInstance3D:
				child.set_instance_shader_parameter("fade", fade)
				child.set_instance_shader_parameter("fade_color", sky_col)
				child.set_instance_shader_parameter("ao_mask", 0.0)
				child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		decor.add_child(node)
		_islands.append(node)


func _spawn_clouds(rng: RandomNumberGenerator) -> void:
	cloud_mat = ShaderMaterial.new()
	cloud_mat.shader = CLOUD_SHADER
	var fog: Color = theme["fog"]
	cloud_mat.set_shader_parameter("color_top", fog.lerp(Color.WHITE, 0.55))
	cloud_mat.set_shader_parameter("color_bottom", fog.lerp(Color(theme["deep"]), 0.18))
	var half_w := cam_size * 0.5 * 16.0 / 9.0
	var count := 13
	for i in count:
		var quad := QuadMesh.new()
		var w := rng.randf_range(6.0, 11.0)
		quad.size = Vector2(w, w * 0.5)
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = cloud_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_instance_shader_parameter("seed", rng.randf() * 100.0)
		mi.basis = camera.basis
		# 前景云（靠近相机、遮住拱廊下部，但不能挡住平台）与远景云
		var front := i % 3 != 0
		var h_quad := w * 0.5
		var sy: float
		if front:
			var top_limit := _near_corner_screen_y() - 0.9
			var lowest := -cam_size * 0.5 - h_quad * 0.1
			sy = rng.randf_range(lowest, top_limit - h_quad * 0.25)
			sy = minf(sy, top_limit - h_quad * 0.25)
		else:
			sy = rng.randf_range(-0.6, 0.1) * cam_size * 0.5
		var depth := rng.randf_range(-12.0, -6.0) if front else rng.randf_range(24.0, 40.0)
		var origin := _screen_to_world(0.0, sy, depth)
		mi.set_instance_shader_parameter("opacity", rng.randf_range(0.75, 0.95) if front else rng.randf_range(0.45, 0.7))
		mi.set_meta("origin", origin)
		mi.set_meta("span", half_w * 2.0 + w * 1.2)
		mi.set_meta("phase", rng.randf() * (half_w * 2.0 + w))
		mi.set_meta("speed", rng.randf_range(0.08, 0.22) * (1.0 if rng.randf() > 0.3 else -1.0))
		decor.add_child(mi)
		_clouds.append(mi)


func apply_theme(theme_id: String) -> void:
	theme = ThemePalette.get_theme(theme_id)
	ThemePalette.apply_globals(theme)
	if mats == null:
		mats = ThemePalette.MaterialLib.new(theme)
	else:
		mats.apply(theme)
	sky_mat.set_shader_parameter("sky_top", theme["sky_top"])
	sky_mat.set_shader_parameter("sky_bottom", theme["sky_bottom"])
	sky_mat.set_shader_parameter("sun_color", theme["sun"])
	var night := theme_id == "night"
	sky_mat.set_shader_parameter("stars", 1.0 if night else 0.0)
	sky_mat.set_shader_parameter("sun_size", 0.035 if night else 0.06)
	sky_mat.set_shader_parameter("cloud_amount", 0.25 if night else 0.6)
	post_mat.set_shader_parameter("vignette_color", Color(theme["deep"]).darkened(0.2))


## 让相机框住整个平台（含塔楼），留出边距。
func frame_level(margin := 1.06) -> void:
	if level == null:
		return
	var top := 1.5
	for p in builder.top_h:
		top = maxf(top, builder.top_h[p] + 0.9)
	var pts: Array[Vector3] = []
	for y in [-1.3, top]:
		pts.append(Vector3(-0.5, y, -0.5))
		pts.append(Vector3(level.width - 0.5, y, -0.5))
		pts.append(Vector3(-0.5, y, level.height - 0.5))
		pts.append(Vector3(level.width - 0.5, y, level.height - 0.5))
	var basis_inv := camera.basis.inverse()
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in pts:
		var q := basis_inv * p
		mn = Vector2(minf(mn.x, q.x), minf(mn.y, q.y))
		mx = Vector2(maxf(mx.x, q.x), maxf(mx.y, q.y))
	var center2 := (mn + mx) * 0.5
	var extent := mx - mn
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	cam_size = maxf(extent.y, extent.x / aspect) * margin
	cam_target = camera.basis * Vector3(center2.x, center2.y, 0.0)
