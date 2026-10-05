extends Node
## 音效与音乐：对象池播放、五声音阶推箱旋律、环境音乐与水声。
##
## 素材由 tools/gen_audio.py 程序合成（audio/ 目录）。缺失的素材会被安全忽略。

const AUDIO_DIR := "res://audio/"
const SFX_NAMES: PackedStringArray = [
	"step", "push", "bump", "target_on", "target_off", "undo", "win", "intro",
	"ui_hover", "ui_click", "editor_place", "editor_erase",
]
const BELL_COUNT := 10

## 每种音效的基础音量（dB），保证混音平衡
## （按 A 计权响度测量结果设定，见 tools/gen_audio.py 的输出）
const BASE_DB := {
	"step": -14.0, "push": -8.0, "bump": -4.5, "target_on": -8.0, "target_off": -11.5,
	"undo": -7.5, "win": -4.0, "intro": -7.5, "ui_hover": -20.0, "ui_click": -12.0,
	"editor_place": -6.0, "editor_erase": -10.0, "bell": -10.0,
}
const MUSIC_DB := -12.5
const WATER_MAX_DB := -12.5

## 推箱旋律：在五声音阶上起伏，连续推箱即形成一段乐句
const MELODY: PackedInt32Array = [0, 2, 4, 3, 5, 4, 2, 3, 5, 7, 6, 4, 5, 3, 2, 1]

var _streams := {}
var _bells: Array[AudioStream] = []
var _pool: Array[AudioStreamPlayer] = []
var _music: AudioStreamPlayer
var _water: AudioStreamPlayer
var _melody_i := 0
## headless（无窗口，Dummy 音频驱动）下不播放：Dummy 驱动不混音，播放实例无法释放
var _silent := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_silent = DisplayServer.get_name() == "headless"
	_ensure_bus("Music")
	_ensure_bus("SFX")
	for n in SFX_NAMES:
		var s := _load(n)
		if s:
			_streams[n] = s
	for i in BELL_COUNT:
		var b := _load("bell_%02d" % i)
		if b:
			_bells.append(b)
	for i in 20:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool.append(p)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	_music.volume_db = MUSIC_DB
	add_child(_music)
	_water = AudioStreamPlayer.new()
	_water.bus = "SFX"
	_water.volume_db = -80.0
	add_child(_water)
	var pad := _load("ambient_pad", true)
	if pad:
		_music.stream = pad
	var water := _load("water_loop", true)
	if water:
		_water.stream = water


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")


func _load(base: String, loop := false) -> AudioStream:
	for ext in [".ogg", ".wav"]:
		var path: String = AUDIO_DIR + base + ext
		if ResourceLoader.exists(path):
			var s: AudioStream = load(path)
			if loop:
				if s is AudioStreamOggVorbis:
					(s as AudioStreamOggVorbis).loop = true
				elif s is AudioStreamWAV and (s as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_DISABLED:
					# 一般由 WAV 内的 smpl 块提供循环点；没有时才退化为整段循环
					var w := s as AudioStreamWAV
					w.loop_mode = AudioStreamWAV.LOOP_FORWARD
					w.loop_begin = 0
					w.loop_end = int(w.get_length() * w.mix_rate)
			return s
	return null


func _player() -> AudioStreamPlayer:
	for p in _pool:
		if not p.playing:
			return p
	return _pool[0]


func play(sfx_name: String, pitch := 1.0, db_offset := 0.0) -> void:
	if _silent:
		return
	var s: AudioStream = _streams.get(sfx_name)
	if s == null:
		return
	var p := _player()
	p.stream = s
	p.pitch_scale = pitch
	p.volume_db = BASE_DB.get(sfx_name, -10.0) + db_offset
	p.play()


func play_bell(index: int, db_offset := 0.0) -> void:
	if _silent:
		return
	if _bells.is_empty():
		return
	var p := _player()
	p.stream = _bells[clampi(index, 0, _bells.size() - 1)]
	p.pitch_scale = 1.0
	p.volume_db = BASE_DB["bell"] + db_offset
	p.play()


## 每次推箱奏出旋律的下一个音。
func play_push_note() -> void:
	play_bell(MELODY[_melody_i % MELODY.size()], -2.0)
	_melody_i += 1


func reset_melody() -> void:
	_melody_i = 0


## 上行琶音（通关时目标依次点亮）。
func play_arpeggio(count: int, interval := 0.12, start := 3) -> void:
	for i in count:
		get_tree().create_timer(interval * i).timeout.connect(play_bell.bind(start + i, -1.0))


func start_music() -> void:
	if _silent:
		return
	if _music.stream and not _music.playing:
		_music.volume_db = -40.0
		_music.play()
		create_tween().tween_property(_music, "volume_db", MUSIC_DB, 3.0)


## 水声音量随场景中的水量变化（0 = 无水）。
func set_water(amount: float) -> void:
	if _silent:
		return
	if _water.stream == null:
		return
	if amount <= 0.0:
		create_tween().tween_property(_water, "volume_db", -60.0, 1.0)
		return
	if not _water.playing:
		_water.volume_db = -60.0
		_water.play()
	create_tween().tween_property(_water, "volume_db", lerpf(WATER_MAX_DB - 12.0, WATER_MAX_DB, clampf(amount, 0.0, 1.0)), 1.5)


func set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))
		AudioServer.set_bus_mute(idx, linear <= 0.001)


## 停止所有播放并释放音频流（退出前调用，避免退出时报告资源泄漏）。
func stop_all() -> void:
	for p in _pool + [_music, _water]:
		p.stop()
		p.stream = null
	_streams.clear()
	_bells.clear()
