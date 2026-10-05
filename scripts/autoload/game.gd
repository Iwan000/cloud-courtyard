extends Node
## 全局：关卡列表、存档进度、设置、输入映射，以及开发用截图。

signal settings_changed

const BUILTIN_DIR := "res://levels/"
const CUSTOM_DIR := "user://levels/"
const PROGRESS_PATH := "user://progress.json"
const SETTINGS_PATH := "user://settings.json"

## 内置关卡（按文件名排序）
var builtin: Array[LevelData] = []
## 工坊关卡（编辑器保存）
var custom: Array[LevelData] = []
## 进度：id -> {completed: bool, best_moves: int, best_pushes: int}
var progress := {}
var settings := {
	"music": 0.7,
	"sfx": 0.85,
	"fullscreen": false,
	"grain": true,
}

## 开发用：命令行 `-- --shot=路径.png [--shot-frames=N]` 渲染 N 帧后保存截图并退出。
var _shot_path := ""
var _shot_frames := 0
var _frame := 0
var cmd_args := {}


## 输入映射：动作 -> 按键（含手柄十字键）
const INPUT_MAP := {
	"move_up": [KEY_W, KEY_UP, JOY_BUTTON_DPAD_UP],
	"move_right": [KEY_D, KEY_RIGHT, JOY_BUTTON_DPAD_RIGHT],
	"move_down": [KEY_S, KEY_DOWN, JOY_BUTTON_DPAD_DOWN],
	"move_left": [KEY_A, KEY_LEFT, JOY_BUTTON_DPAD_LEFT],
	"undo": [KEY_Z, KEY_BACKSPACE, JOY_BUTTON_B],
	"redo": [KEY_Y, JOY_BUTTON_Y],
	"restart": [KEY_R, JOY_BUTTON_BACK],
	"pause": [KEY_ESCAPE, JOY_BUTTON_START],
	"hint": [KEY_H],
}


func _register_input() -> void:
	for action in INPUT_MAP:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		var keys: Array = INPUT_MAP[action]
		for i in keys.size():
			var code: int = keys[i]
			if i == keys.size() - 1 and action != "hint":
				var jb := InputEventJoypadButton.new()
				jb.button_index = code
				InputMap.action_add_event(action, jb)
			else:
				var ev := InputEventKey.new()
				ev.physical_keycode = code
				InputMap.action_add_event(action, ev)


func _ready() -> void:
	_register_input()
	load_builtin_levels()
	load_custom_levels()
	_load_progress()
	_load_settings()
	apply_settings()
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


# ---------------------------------------------------------------------------
# 关卡
# ---------------------------------------------------------------------------

func load_builtin_levels() -> void:
	builtin.clear()
	var dir := DirAccess.open(BUILTIN_DIR)
	if dir == null:
		return
	var files := Array(dir.get_files()).filter(func(f: String): return f.ends_with(".json"))
	files.sort()
	for f in files:
		var lvl := LevelData.load_file(BUILTIN_DIR + f)
		if lvl:
			builtin.append(lvl)


func load_custom_levels() -> void:
	custom.clear()
	DirAccess.make_dir_recursive_absolute(CUSTOM_DIR)
	var dir := DirAccess.open(CUSTOM_DIR)
	if dir == null:
		return
	var files := Array(dir.get_files()).filter(func(f: String): return f.ends_with(".json"))
	files.sort()
	for f in files:
		var lvl := LevelData.load_file(CUSTOM_DIR + f)
		if lvl:
			if lvl.id == "":
				lvl.id = "custom_" + f.get_basename()
			custom.append(lvl)


## 保存工坊关卡；id 为空时自动分配。返回保存后的 id。
func save_custom_level(lvl: LevelData) -> String:
	DirAccess.make_dir_recursive_absolute(CUSTOM_DIR)
	if lvl.id == "" or not lvl.id.begins_with("custom_"):
		lvl.id = "custom_%d" % int(Time.get_unix_time_from_system())
	lvl.save_file(CUSTOM_DIR + lvl.id.trim_prefix("custom_") + ".json")
	load_custom_levels()
	return lvl.id


func delete_custom_level(lvl: LevelData) -> void:
	var path := CUSTOM_DIR + lvl.id.trim_prefix("custom_") + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	load_custom_levels()


func builtin_index(lvl: LevelData) -> int:
	for i in builtin.size():
		if builtin[i].id == lvl.id:
			return i
	return -1


## 内置关卡按顺序解锁：第一关始终可玩，其余需通过上一关。
func is_unlocked(index: int) -> bool:
	if index <= 0 or cmd_args.has("unlock-all"):
		return true
	return is_completed(builtin[index - 1].id)


func is_completed(level_id: String) -> bool:
	return progress.get(level_id, {}).get("completed", false)


func best_moves(level_id: String) -> int:
	return int(progress.get(level_id, {}).get("best_moves", -1))


## 下一个应当游玩的内置关卡下标（第一个未完成且已解锁的关卡）。
func next_level_index() -> int:
	for i in builtin.size():
		if not is_completed(builtin[i].id):
			return i
	return 0


# ---------------------------------------------------------------------------
# 进度
# ---------------------------------------------------------------------------

## 记录通关；返回是否刷新了最佳步数。
func record_completion(lvl: LevelData, moves: int, pushes: int) -> bool:
	if lvl.id == "":
		return false
	var entry: Dictionary = progress.get(lvl.id, {})
	var prev := int(entry.get("best_moves", -1))
	var improved := prev < 0 or moves < prev
	entry["completed"] = true
	if improved:
		entry["best_moves"] = moves
		entry["best_pushes"] = pushes
	progress[lvl.id] = entry
	_save_json(PROGRESS_PATH, progress)
	return improved


func reset_progress() -> void:
	progress = {}
	_save_json(PROGRESS_PATH, progress)


func _load_progress() -> void:
	var d: Variant = _load_json(PROGRESS_PATH)
	progress = d if d is Dictionary else {}


# ---------------------------------------------------------------------------
# 设置
# ---------------------------------------------------------------------------

func set_setting(key: String, value: Variant) -> void:
	settings[key] = value
	apply_settings()
	_save_json(SETTINGS_PATH, settings)
	settings_changed.emit()


func apply_settings() -> void:
	Sfx.set_bus_volume("Music", float(settings["music"]))
	Sfx.set_bus_volume("SFX", float(settings["sfx"]))
	if not cmd_args.has("shot"):
		var fs: bool = settings["fullscreen"]
		var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fs else DisplayServer.WINDOW_MODE_WINDOWED
		if DisplayServer.window_get_mode() != mode and (fs or DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN):
			DisplayServer.window_set_mode(mode)


func _load_settings() -> void:
	var d: Variant = _load_json(SETTINGS_PATH)
	if d is Dictionary:
		for k in d:
			if settings.has(k):
				settings[k] = d[k]


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

static func _save_json(path: String, data: Variant) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "  "))


static func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f else null
