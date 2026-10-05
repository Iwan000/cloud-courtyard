extends Node
## 全局：关卡列表、存档、设置、开发用截图。

## 开发用：命令行 `-- --shot=路径.png [--shot-frames=N]` 渲染 N 帧后保存截图并退出。
var _shot_path := ""
var _shot_frames := 0
var _frame := 0
var cmd_args := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			cmd_args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	_shot_path = cmd_args.get("shot", "")
	_shot_frames = int(cmd_args.get("shot-frames", "45"))
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if _shot_path == "":
		return
	_frame += 1
	if _frame == _shot_frames:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(_shot_path)
		print("[shot] saved ", _shot_path, " ", img.get_size())
		get_tree().quit()
