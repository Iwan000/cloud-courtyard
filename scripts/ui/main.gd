extends Node
## 游戏主流程状态机：标题 → 选关 → 关卡 → 结算，以及暂停、设置、提示、编辑器试玩。
## 3D 世界（World/BoardView）常驻，各界面只是叠加在其上的 UI 层。

enum Screen { NONE, TITLE, SELECT, PLAY, COMPLETE, EDITOR }

var world: World
var board: BoardView
var controller: PlayController
var director: LevelDirector
var hints := HintService.new()

var ui: CanvasLayer
var ui_root: Control
var screen := Screen.NONE
var screen_node: Control
var hud: Hud
var pause_menu: PauseMenu
var settings_panel: SettingsPanel
var editor: LevelEditor

var state: SokobanState
var current_level: LevelData
var testing_from_editor := false
var _transitioning := false
var _preview_pending: LevelData
var _previewing := false
var _hint_waiting := false
var _demo: TitleDemo     ## 标题画面的演示循环（离开标题时释放）

## 标题画面的演示：一条走廊，小兵把石箱一格一格推到印记上，然后循环。
## 不属于关卡列表，只用来让人一眼看出这是推箱子游戏。
const TITLE_DEMO_MAP := ["########", "#@$---.#", "########"]
const TITLE_DEMO_SEED := 2024


func _ready() -> void:
	world = World.new()
	world.name = "World"
	add_child(world)
	board = BoardView.new()
	board.name = "Board"
	world.add_child(board)
	board.visible = false
	controller = PlayController.new()
	controller.name = "PlayController"
	add_child(controller)
	director = LevelDirector.new()
	director.name = "Director"
	add_child(director)
	director.setup(world, board)
	controller.solved.connect(_on_solved)
	controller.counters_changed.connect(func(m, p):
		if hud:
			hud.set_counters(m, p))
	controller.restart_requested.connect(_restart)
	controller.pause_requested.connect(_open_pause)
	controller.hint_requested.connect(_hint)
	controller.view_toggle_requested.connect(_toggle_view)

	ui = CanvasLayer.new()
	ui.layer = 10
	add_child(ui)
	ui_root = Control.new()
	ui_root.name = "UI"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(ui_root)

	Game.settings_changed.connect(_apply_visual_settings)
	_apply_visual_settings()
	_set_ui_theme(ThemePalette.get_theme("dawn"))
	Sfx.start_music()

	var args := Game.cmd_args
	if args.has("smoke"):
		Game.cmd_args["unlock-all"] = "true"
		add_child(load("res://tests/smoke.gd").new())
		return
	if args.has("level"):
		var lvl := LevelData.load_file("res://levels/%s.json" % args["level"])
		await play_level(lvl)
		if args.has("autoplay"):
			var lurd: String = args["autoplay"]
			if lurd.begins_with("solution"):
				var solver := SokobanSolver.new()
				solver.solve(lvl)
				lurd = solver.solution
				if args["autoplay"].contains(":"):
					lurd = lurd.substr(0, int(args["autoplay"].get_slice(":", 1)))
			controller.play_lurd(lurd)
		if args.has("zoom"):
			world.cam_size = float(args["zoom"])
		if args.has("open"):
			match args["open"]:
				"pause":
					_open_pause()
				"settings":
					_open_settings()
				"hint":
					_hint()
				"topdown":
					_toggle_view()
	elif args.get("screen", "") == "select":
		go_select(args.get("select", ""))
	elif args.get("screen", "") == "editor":
		var src: LevelData = null
		if args.has("edit"):
			src = LevelData.load_file("res://levels/%s.json" % args["edit"])
		go_editor(src)
		if args.get("open", "") == "topdown":
			editor._toggle_view()
	else:
		go_title()


func _apply_visual_settings() -> void:
	world.post_mat.set_shader_parameter("grain", 0.03 if Game.settings["grain"] else 0.0)


func _set_ui_theme(theme: Dictionary) -> void:
	UiKit.set_theme_colors(theme)
	ui_root.theme = UiKit.make_theme()


func _clear_screen() -> void:
	if _demo and is_instance_valid(_demo):
		_demo.queue_free()
	_demo = null
	for n in [screen_node, hud]:
		if n and is_instance_valid(n):
			n.queue_free()
	screen_node = null
	hud = null


## 切换到某关的场景（只有建筑，没有箱子与角色），用于标题与选关背景。
func _show_scenery(lvl: LevelData, offset: Vector2) -> void:
	if world.monument and (world.level != lvl or board.visible):
		await director.play_outro(board.visible)
	world.set_top_down(false, false)
	board.visible = false
	world.load_level(lvl, true, offset)
	_set_ui_theme(world.theme)
	director.play_intro(false)


# ---------------------------------------------------------------------------
# 标题
# ---------------------------------------------------------------------------

func go_title() -> void:
	_clear_screen()
	_close_editor()
	controller.stop()
	screen = Screen.TITLE
	if Game.builtin.is_empty():
		return
	var lvl: LevelData = Game.builtin[Game.next_level_index()]
	await _show_title_demo(lvl.theme)
	var t := TitleScreen.new()
	ui_root.add_child(t)
	t.build()
	t.start_pressed.connect(func(): play_level(Game.builtin[Game.next_level_index()]))
	t.select_pressed.connect(func(): go_select())
	t.editor_pressed.connect(func(): go_editor(null))
	t.settings_pressed.connect(_open_settings)
	t.quit_pressed.connect(func(): Game.quit_game())
	screen_node = t
	t.focus_first()


func _show_title_demo(theme_id: String) -> void:
	var demo := LevelData.from_rows(PackedStringArray(TITLE_DEMO_MAP))
	demo.theme = theme_id
	demo.decor_seed = TITLE_DEMO_SEED
	if world.monument:
		await director.play_outro(board.visible)
	world.set_top_down(false, false)
	world.load_level(demo, true, Vector2(0.2, 0.0), 1.35)
	_set_ui_theme(world.theme)
	var st := SokobanState.new(demo)
	board.setup(st, world.mats, world.theme)
	board.visible = false
	_demo = TitleDemo.new()
	_demo.board = board
	_demo.state = st
	add_child(_demo)
	_start_title_demo(_demo)


func _start_title_demo(demo: TitleDemo) -> void:
	await director.play_intro(true)
	if is_instance_valid(demo) and demo == _demo:
		board.quiet = true
		board.speed = 0.5
		demo.running = true


## 标题演示：小兵一步一步把石箱推到印记上，停留片刻后复位，循环。
## 逐帧推进而不用协程等待：退出游戏时不会留下挂起的协程。
class TitleDemo:
	extends Node
	var board: BoardView
	var state: SokobanState
	var running := false
	var _phase := "wait"
	var _timer := 1.0

	func _process(delta: float) -> void:
		if not running or board.is_busy():
			return
		_timer -= delta
		if _timer > 0.0:
			return
		match _phase:
			"wait":
				_phase = "push"
			"push":
				if state.is_solved():
					_phase = "hold"
					_timer = 2.8
				else:
					board.play(state.move(SokobanState.Dir.RIGHT))
					_timer = 0.55
			"hold":
				state.reset()
				board.play_reset()
				_phase = "wait"
				_timer = 1.6


# ---------------------------------------------------------------------------
# 选关
# ---------------------------------------------------------------------------

func go_select(select_id := "") -> void:
	_clear_screen()
	if not testing_from_editor:
		_close_editor()
	controller.stop()
	director.stop_camera()
	screen = Screen.SELECT
	if select_id == "" and current_level:
		select_id = current_level.id
	_build_select(select_id)


func _build_select(select_id: String) -> void:
	if screen_node and is_instance_valid(screen_node):
		screen_node.queue_free()
	var s := LevelSelect.new()
	ui_root.add_child(s)
	screen_node = s
	s.selection_changed.connect(_preview)
	s.play_level.connect(func(l): play_level(l))
	s.edit_level.connect(func(l): go_editor(l))
	s.new_level.connect(func(): go_editor(null))
	s.back.connect(func(): go_title())
	s.build(select_id)


## 选关预览：切换到所选关卡的建筑（连续快速切换时只处理最后一次）。
func _preview(lvl: LevelData) -> void:
	_preview_pending = lvl
	if _previewing:
		return
	_previewing = true
	while _preview_pending != null:
		var l := _preview_pending
		_preview_pending = null
		if world.level == l and not board.visible:
			continue
		var was_night := _is_night(world.theme)
		if world.monument:
			await director.play_outro(board.visible)
		board.visible = false
		world.set_top_down(false, false)
		if screen != Screen.SELECT:
			break
		world.load_level(l, true, Vector2(0.2, 0.0), 1.22)
		if _is_night(world.theme) != was_night:
			_set_ui_theme(world.theme)
			_build_select(l.id)
		director.play_intro(false)
		await get_tree().create_timer(0.35).timeout
	_previewing = false


static func _is_night(theme: Dictionary) -> bool:
	return not theme.is_empty() and Color(theme["sky_top"]).get_luminance() < 0.3


# ---------------------------------------------------------------------------
# 关卡
# ---------------------------------------------------------------------------

func play_level(lvl: LevelData, from_editor := false) -> void:
	if _transitioning or lvl == null:
		return
	_transitioning = true
	testing_from_editor = from_editor
	_clear_screen()
	controller.stop()
	hints.cancel()
	screen = Screen.PLAY
	current_level = lvl
	if world.monument:
		await director.play_outro(board.visible)
	world.set_top_down(false, false)
	world.load_level(lvl, true)
	_set_ui_theme(world.theme)
	state = SokobanState.new(lvl)
	board.setup(state, world.mats, world.theme)
	board.visible = false
	Sfx.reset_melody()
	var idx := Game.builtin_index(lvl)
	var card := TitleCard.new()
	ui_root.add_child(card)
	card.show_card(UiKit.roman(idx + 1) if idx >= 0 else "", lvl.name)
	await director.play_intro(true)
	hud = Hud.new()
	ui_root.add_child(hud)
	hud.build(lvl, UiKit.roman(idx + 1) if idx >= 0 else "")
	hud.undo_pressed.connect(controller.undo)
	hud.restart_pressed.connect(_restart)
	hud.menu_pressed.connect(_open_pause)
	hud.hint_pressed.connect(_hint)
	hud.view_pressed.connect(_toggle_view)
	hud.show_objective("将 %d 只石箱推到发光的印记上" % lvl.boxes.size())
	controller.begin(state, board, world)
	_transitioning = false
	if lvl.has_meta("autoplay") and lvl.solution != "":
		hud.show_objective("演示最优解：%d 步" % lvl.solution.length(), 2.5)
		controller.play_lurd(lvl.solution)


## 关卡内切换俯视视角（Tab / V）。
func _toggle_view() -> void:
	if screen != Screen.PLAY:
		return
	world.set_top_down(not world.is_top_down())
	Sfx.play("ui_click")


func _restart() -> void:
	if screen != Screen.PLAY or _transitioning:
		return
	_transitioning = true
	controller.stop()
	state.reset()
	Sfx.reset_melody()
	Sfx.play("undo", 0.8)
	await board.play_reset()
	controller.begin(state, board, world)
	_transitioning = false


func _hint() -> void:
	if screen != Screen.PLAY or not controller.accepting:
		return
	hints.request(state)
	_hint_waiting = true
	if hud:
		hud.show_objective("思索中……", 0.6)


func _process(_delta: float) -> void:
	if _hint_waiting and state:
		var res := hints.poll(state)
		if not res.is_empty():
			_hint_waiting = false
			_show_hint(res)


func _show_hint(res: Dictionary) -> void:
	if hud == null:
		return
	match res["status"]:
		SokobanSolver.Status.SOLVED:
			var walk: Array[int] = res["walk"]
			var p := state.player
			for d in walk:
				p += SokobanState.DIRS[d]
			var box_cell: Vector2i = p + SokobanState.DIRS[res["push_dir"]]
			board.show_hint(state.box_at(box_cell), res["push_dir"], walk)
			var dir_names := ["上", "右", "下", "左"]
			var how := "沿虚线走过去，" if not walk.is_empty() else ""
			hud.show_objective("提示：%s把发光的石箱向%s推" % [how, dir_names[res["push_dir"]]], 2.5)
		SokobanSolver.Status.UNSOLVABLE:
			hud.show_objective("此局已无解——试试撤销（Z）或重来（R）", 3.0)
		_:
			hud.show_objective("这一步太复杂，暂时想不出来", 2.0)


func _on_solved() -> void:
	screen = Screen.COMPLETE
	hints.cancel()
	if hud:
		hud.fade_out()
	var lvl := current_level
	var improved := false
	if not testing_from_editor:
		improved = Game.record_completion(lvl, state.moves, state.pushes)
	await director.play_complete()
	var idx := Game.builtin_index(lvl)
	var has_next := idx >= 0 and idx + 1 < Game.builtin.size()
	var panel := CompletePanel.new()
	ui_root.add_child(panel)
	panel.build(lvl, state.moves, state.pushes, Game.best_moves(lvl.id), improved and Game.best_moves(lvl.id) > 0, has_next, testing_from_editor)
	panel.next_pressed.connect(func(): play_level(Game.builtin[idx + 1]))
	panel.replay_pressed.connect(func(): play_level(lvl, testing_from_editor))
	panel.select_pressed.connect(func():
		if testing_from_editor:
			go_editor(lvl)
		else:
			go_select(lvl.id))
	screen_node = panel
	panel.focus_default()
	# 开发用：--then=NN 结算后自动进入指定关卡（用于录制关卡切换）
	if Game.cmd_args.has("then"):
		await get_tree().create_timer(2.5).timeout
		play_level(LevelData.load_file("res://levels/%s.json" % Game.cmd_args["then"]))


# ---------------------------------------------------------------------------
# 暂停与设置
# ---------------------------------------------------------------------------

func _open_pause() -> void:
	if screen != Screen.PLAY or _transitioning or (pause_menu and pause_menu.visible):
		return
	controller.accepting = false
	if pause_menu == null:
		pause_menu = PauseMenu.new()
		ui_root.add_child(pause_menu)
		pause_menu.build(testing_from_editor)
		pause_menu.resume.connect(func():
			await pause_menu.close()
			if screen == Screen.PLAY:
				controller.accepting = true)
		pause_menu.restart.connect(func():
			await pause_menu.close()
			controller.accepting = true
			_restart())
		pause_menu.settings.connect(_open_settings)
		pause_menu.to_select.connect(func():
			await pause_menu.close()
			if testing_from_editor:
				go_editor(current_level)
			else:
				go_select())
		pause_menu.to_title.connect(func():
			await pause_menu.close()
			go_title())
	ui_root.move_child(pause_menu, -1)
	pause_menu.open()


func _open_settings() -> void:
	if settings_panel == null:
		settings_panel = SettingsPanel.new()
		ui_root.add_child(settings_panel)
		settings_panel.build()
	ui_root.move_child(settings_panel, -1)
	settings_panel.open()


# ---------------------------------------------------------------------------
# 编辑器
# ---------------------------------------------------------------------------

## 进入编辑器。从试玩返回时恢复原编辑器（撤销历史等状态完整保留）。
func go_editor(lvl: LevelData) -> void:
	_clear_screen()
	controller.stop()
	hints.cancel()
	director.stop_camera()
	screen = Screen.EDITOR
	board.visible = false
	world.set_top_down(false, false)
	if editor and is_instance_valid(editor) and testing_from_editor:
		testing_from_editor = false
		editor.resume()
		_set_ui_theme(world.theme)
		return
	_close_editor()
	editor = LevelEditor.new()
	ui_root.add_child(editor)
	editor.test_play.connect(func(l):
		editor.suspend()
		play_level(l, true))
	editor.exit.connect(func():
		_close_editor()
		go_select())
	editor.palette_changed.connect(func(): _set_ui_theme(world.theme))
	_set_ui_theme(ThemePalette.get_theme(lvl.theme if lvl else "dawn"))
	editor.open(world, director, lvl)
	_set_ui_theme(world.theme)


func _close_editor() -> void:
	if editor and is_instance_valid(editor):
		editor.queue_free()
	editor = null
