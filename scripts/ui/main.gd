extends Node
## 流程状态机（look-dev 阶段：直接加载一关）。

var world: World

const LOOKDEV_MAP := [
	"   #######",
	"  ##-----##",
	"  #--$-.--#",
	"###-#--$#-#",
	"#-.---@---#",
	"#---$-#.--#",
	"###----####",
	"  ######",
]


func _ready() -> void:
	world = World.new()
	world.name = "World"
	add_child(world)
	var lvl := LevelData.from_rows(PackedStringArray(LOOKDEV_MAP))
	lvl.theme = Game.cmd_args.get("theme", "dawn")
	lvl.seed = 7
	world.load_level(lvl)
	var board := BoardView.new()
	board.name = "Board"
	world.add_child(board)
	board.setup(SokobanState.new(lvl), world.mats)
	if Game.cmd_args.has("debug-shadow"):
		RenderingServer.global_shader_parameter_set("mv_shadow_color", Color(1, 0, 0))
	if Game.cmd_args.has("zoom"):
		world.cam_size = float(Game.cmd_args["zoom"])
