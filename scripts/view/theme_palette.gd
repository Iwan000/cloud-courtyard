class_name ThemePalette
extends RefCounted
## 主题色板：每关一套。定义天空/雾/阴影等全局色，以及每种材质的 顶/左/右 三色。
##
## 新增主题：在 THEMES 中加一项并在 LevelData.THEMES 中登记即可，
## 建筑生成器与材质库会自动使用。

const MV_SHADER := preload("res://shaders/mv_surface.gdshader")

## 材质键 → [顶, 左, 右]
const MATERIAL_KEYS: PackedStringArray = [
	"floor", "wall", "trim", "base", "arcade", "tower", "roof", "box", "box_panel",
	"window", "trunk", "foliage", "planter", "stair", "cloak", "hat", "skin", "scarf", "legs",
	"box_glyph", "target",
]

static var THEMES := {
	"dawn": {
		"title": "晨曦", "title_en": "Dawn",
		"sky_top": Color("9fd6e6"), "sky_bottom": Color("f6e7e3"), "sun": Color("fff6ea"),
		"fog": Color("f1e4ea"), "deep": Color("b7a6dc"), "shadow": Color("b9a5dd"),
		"target": Color("8fcab3"), "target_glow": Color("d9fff0"), "water": Color("8fd9e4"),
		"floor": ["f7eadf", "ecc9bd", "dfb0a6"],
		"wall": ["f9e3d6", "eeb6a9", "dc928a"],
		"trim": ["fff3e6", "f6d9c9", "eec2b4"],
		"base": ["f6dccf", "eab0a4", "d68c86"],
		"arcade": ["f3d2c7", "e2a39b", "cc8481"],
		"tower": ["fae6da", "efbcad", "de968d"],
		"roof": ["a7dbd1", "86c4ba", "62a69d"],
		"box": ["c3bdf4", "958de0", "746bc8"],
		"box_panel": ["d6d1fb", "a59ee9", "8279d3"],
		"window": ["b98f9a", "c99aa2", "a87781"],
		"trunk": ["a77a6e", "8e6258", "754e48"],
		"foliage": ["fbc2d0", "f39fb5", "e37f9c"],
		"planter": ["f4dccd", "e6b3a3", "d29486"],
		"stair": ["f8e6da", "ecbfb1", "dc9c90"],
		"cloak": ["f2858b", "df6a74", "c4525f"],
		"hat": ["f0d9a3", "dcbd7e", "c4a163"],
		"skin": ["f7e3d2", "edcfba", "dcb9a2"],
		"scarf": ["fff6ea", "f1e4d6", "dfcfbf"],
		"legs": ["5b4a6b", "4a3b59", "3a2e48"],
	},
	"garden": {
		"title": "碧水", "title_en": "Garden",
		"sky_top": Color("b9e8e3"), "sky_bottom": Color("fff1dc"), "sun": Color("fffbe8"),
		"fog": Color("e6f2e6"), "deep": Color("7fb8b6"), "shadow": Color("98c2bf"),
		"target": Color("f2a48e"), "target_glow": Color("fff0e0"), "water": Color("7fd8e3"),
		"floor": ["f5ead2", "e4d2b3", "d1bb98"],
		"wall": ["e8f3e5", "a3d5c9", "70b5a9"],
		"trim": ["f7fbf2", "cfe9df", "a9d6ca"],
		"base": ["e0efe3", "98cdc0", "68ab9f"],
		"arcade": ["d6ebdf", "8cc3b6", "5e9e93"],
		"tower": ["eef6ea", "b2dccf", "7ebdaf"],
		"roof": ["f0a37e", "de8562", "c86c4f"],
		"box": ["f8b29b", "e6846f", "cc6655"],
		"box_panel": ["fbc8b6", "efa08c", "d97e6c"],
		"window": ["6e9c97", "7aa8a2", "5f8a85"],
		"trunk": ["9a7a62", "7f624f", "684f41"],
		"foliage": ["c9e7a4", "a8d686", "86bd6d"],
		"planter": ["eae0c6", "d6c6a4", "c0ad88"],
		"stair": ["eef6ea", "b8ddd2", "86c0b3"],
		"cloak": ["6386dc", "4c6cc4", "3c57a8"],
		"hat": ["f0d9a3", "dcbd7e", "c4a163"],
		"skin": ["f7e3d2", "edcfba", "dcb9a2"],
		"scarf": ["f6b35e", "e7964a", "cc7b3a"],
		"legs": ["3f5a5d", "334b4e", "283c3f"],
	},
	"dusk": {
		"title": "暮霞", "title_en": "Dusk",
		"sky_top": Color("f4a9a0"), "sky_bottom": Color("fde3c4"), "sun": Color("fff1d6"),
		"fog": Color("f8dccd"), "deep": Color("9a6aa8"), "shadow": Color("cf96ae"),
		"target": Color("6fc6c3"), "target_glow": Color("e8fffd"), "water": Color("8fd3da"),
		"floor": ["fce8c9", "efcfa6", "dfb688"],
		"wall": ["ffe2b2", "f6b36d", "df8b50"],
		"trim": ["fff2d6", "fbd39b", "efb276"],
		"base": ["fbd6a1", "eea062", "d17a48"],
		"arcade": ["f6c891", "e39257", "c46e41"],
		"tower": ["ffe6bd", "f7bd7e", "e3955b"],
		"roof": ["d85f68", "c04a57", "a33a49"],
		"box": ["79cdca", "47a3a6", "317f8a"],
		"box_panel": ["9bdcd8", "62b7b8", "45959d"],
		"window": ["9a5a5f", "aa6467", "874b52"],
		"trunk": ["8f5d4c", "774b3e", "613d34"],
		"foliage": ["ffb3a1", "f78f86", "e2706f"],
		"planter": ["f9dcb0", "ecbc85", "d89e6c"],
		"stair": ["ffe8c4", "f6c088", "e09a62"],
		"cloak": ["9a6bb0", "7f5596", "65427a"],
		"hat": ["f0d9a3", "dcbd7e", "c4a163"],
		"skin": ["f7e3d2", "edcfba", "dcb9a2"],
		"scarf": ["fff3e0", "f2e0c8", "dfc9ad"],
		"legs": ["5a3f55", "4a3346", "3b2938"],
	},
	"lavender": {
		"title": "紫境", "title_en": "Lavender",
		"sky_top": Color("c3cff6"), "sky_bottom": Color("f6dbeb"), "sun": Color("fff3f8"),
		"fog": Color("ecdcef"), "deep": Color("8e86d6"), "shadow": Color("bba8e6"),
		"target": Color("e8707f"), "target_glow": Color("ffe3e8"), "water": Color("9fd6f0"),
		"floor": ["f8e6dc", "edcabd", "dfb0a5"],
		"wall": ["fbdcd9", "f3abb9", "e0869b"],
		"trim": ["fff1e3", "fbe0b9", "f2cb98"],
		"base": ["f8d2d4", "ef9fb0", "d97f95"],
		"arcade": ["f1c3c9", "e392a5", "c97590"],
		"tower": ["fce2dc", "f5b7bf", "e4929f"],
		"roof": ["a28df0", "8570dd", "6a57c4"],
		"box": ["b1aaf5", "857de0", "665ec7"],
		"box_panel": ["c9c4fb", "9f98ec", "7e76d6"],
		"window": ["a77393", "b57e9d", "93647f"],
		"trunk": ["8f6a6a", "775656", "614646"],
		"foliage": ["f7b5e0", "eb95cf", "d877bb"],
		"planter": ["f8d8d2", "edb3b6", "dc929d"],
		"stair": ["fde6de", "f4bcc2", "e297a5"],
		"cloak": ["6cc2b6", "4fa79c", "3b8a82"],
		"hat": ["f3dcae", "e0c088", "c8a56c"],
		"skin": ["f7e3d2", "edcfba", "dcb9a2"],
		"scarf": ["fff3e0", "f2dfc6", "dcc6a8"],
		"legs": ["3d3557", "312a47", "262139"],
	},
	"night": {
		"title": "星夜", "title_en": "Starry Night",
		"sky_top": Color("10133a"), "sky_bottom": Color("3d2f7c"), "sun": Color("f4f0ff"),
		"fog": Color("2c2a6a"), "deep": Color("1b1d4d"), "shadow": Color("3f3a86"),
		"target": Color("ffd27a"), "target_glow": Color("fff1c8"), "water": Color("6fa8e8"),
		"floor": ["8e88d9", "6f69c0", "5853a8"],
		"wall": ["7470cf", "5450b0", "3c3994"],
		"trim": ["a9a3ef", "8a84dc", "6f69c4"],
		"base": ["6a66c4", "4c48a4", "36338a"],
		"arcade": ["5f5bb8", "45419a", "312e80"],
		"tower": ["7c78d6", "5a56b6", "413e9a"],
		"roof": ["4fc0d0", "3aa1b6", "2b8199"],
		"box": ["ffd894", "f3b163", "d98e40"],
		"box_panel": ["ffe6b6", "f8c584", "e6a45d"],
		"window": ["ffd27a", "ffc966", "f2b453"],
		"trunk": ["5a4a7a", "4a3c66", "3b2f54"],
		"foliage": ["7fe0d6", "5cc6c4", "45a6ae"],
		"planter": ["7a76d2", "5955b2", "403d96"],
		"stair": ["8984dc", "6661c0", "4b47a4"],
		"cloak": ["f4f0ff", "d9d3f2", "b9b1e0"],
		"hat": ["f3dcae", "e0c088", "c8a56c"],
		"skin": ["f7e3d2", "edcfba", "dcb9a2"],
		"scarf": ["ff9f8a", "f07f73", "d6645e"],
		"legs": ["24204a", "1c193d", "151230"],
	},
}


static func get_theme(theme_id: String) -> Dictionary:
	return THEMES.get(theme_id, THEMES["dawn"])


static func tri(theme: Dictionary, key: String) -> Array[Color]:
	var arr: Array = theme.get(key, ["ffffff", "cccccc", "999999"])
	return [Color(arr[0]), Color(arr[1]), Color(arr[2])]


## 把主题的全局色写入全局 shader 参数（雾、深色、阴影色）。
static func apply_globals(theme: Dictionary) -> void:
	RenderingServer.global_shader_parameter_set("mv_fog_color", theme["fog"])
	RenderingServer.global_shader_parameter_set("mv_deep_color", theme["deep"])
	RenderingServer.global_shader_parameter_set("mv_shadow_color", theme["shadow"])


## 材质库：一套主题对应一组 ShaderMaterial，可以整体切换主题（带颜色过渡）。
class MaterialLib:
	extends RefCounted
	var materials := {}

	func _init(theme: Dictionary) -> void:
		for key in ThemePalette.MATERIAL_KEYS:
			var m := ShaderMaterial.new()
			m.shader = ThemePalette.MV_SHADER
			materials[key] = m
		var floor_m: ShaderMaterial = materials["floor"]
		floor_m.set_shader_parameter("pattern", 1)
		floor_m.set_shader_parameter("pattern_strength", 0.07)
		for key in ["wall", "base", "arcade", "tower"]:
			var mm: ShaderMaterial = materials[key]
			mm.set_shader_parameter("pattern", 2)
			mm.set_shader_parameter("pattern_strength", 0.035)
		var tm: ShaderMaterial = materials["target"]
		tm.set_shader_parameter("pattern", 3)
		tm.set_shader_parameter("ao_amount", 0.6)
		for key in ["box", "box_panel", "box_glyph", "cloak", "hat", "skin", "scarf", "legs"]:
			var am: ShaderMaterial = materials[key]
			am.set_shader_parameter("ao_amount", 0.0)
		apply(theme)

	func apply(theme: Dictionary) -> void:
		for key in materials:
			if key == "box_glyph" or key == "target":
				continue
			var c := ThemePalette.tri(theme, key)
			var m: ShaderMaterial = materials[key]
			m.set_shader_parameter("color_top", c[0])
			m.set_shader_parameter("color_left", c[1])
			m.set_shader_parameter("color_right", c[2])
		var win: ShaderMaterial = materials["window"]
		win.set_shader_parameter("emission_color", Color(theme["window"][0]))
		win.set_shader_parameter("emission_energy", 2.2)
		# 箱子符号：比箱身更深，入位时发光
		var bc := ThemePalette.tri(theme, "box")
		var panel: ShaderMaterial = materials["box_panel"]
		panel.set_shader_parameter("color_top", bc[0].darkened(0.06))
		panel.set_shader_parameter("color_left", bc[1].darkened(0.08))
		panel.set_shader_parameter("color_right", bc[2].darkened(0.1))
		var glyph: ShaderMaterial = materials["box_glyph"]
		glyph.set_shader_parameter("color_top", bc[0].lightened(0.35))
		glyph.set_shader_parameter("color_left", bc[1].lightened(0.3))
		glyph.set_shader_parameter("color_right", bc[2].lightened(0.25))
		glyph.set_shader_parameter("emission_color", theme["target_glow"])
		glyph.set_shader_parameter("emission_energy", 2.4)
		# 目标地砖：底色取地面色与目标色的混合，图案为目标色
		var fc := ThemePalette.tri(theme, "floor")
		var tc: Color = theme["target"]
		var target: ShaderMaterial = materials["target"]
		target.set_shader_parameter("color_top", fc[0].lerp(tc, 0.55))
		target.set_shader_parameter("color_left", fc[1])
		target.set_shader_parameter("color_right", fc[2])
		target.set_shader_parameter("pattern_color", fc[0].lerp(Color.WHITE, 0.5))
		target.set_shader_parameter("emission_color", theme["target_glow"])
		target.set_shader_parameter("emission_energy", 1.8)

	func get_mat(key: String) -> ShaderMaterial:
		return materials[key]
