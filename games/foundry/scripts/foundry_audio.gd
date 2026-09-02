class_name FoundryAudio
extends Node
## BGM 循环 + 静音开关（v2.5 从 main.gd 拆出）
## - bgm_loop.wav: tools/gen_bgm.py 产出的 8-bit 循环曲，运行时设 LOOP_FORWARD
## - 静音状态记忆到浏览器 localStorage（仅 Web），按键为 foundry_muted

const MUTE_KEY := "foundry_muted"

var _bgm: AudioStreamPlayer
var _muted: bool = false
var _btn: TextureButton


## toggle_cb: Callable（由 main 处理点击音效后再调 toggle()）
func setup(root: Control, toggle_cb: Callable) -> void:
	var s := _load_audio("res://assets/audio/bgm_loop.wav")
	if s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = w.data.size() / 2  # 16-bit mono 帧数
	_bgm = AudioStreamPlayer.new()
	_bgm.stream = s
	_bgm.volume_db = -12.0
	_bgm.bus = "Master"
	root.add_child(_bgm)

	_btn = TextureButton.new()
	_btn.ignore_texture_size = true
	_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_btn.position = Vector2(648, 1196)
	_btn.size = Vector2(64, 64)
	_btn.focus_mode = Control.FOCUS_NONE
	_btn.pressed.connect(toggle_cb)
	root.add_child(_btn)

	_apply(_load_muted(), false)
	if not _muted:
		_bgm.play()


func btn() -> TextureButton:
	return _btn


func is_muted() -> bool:
	return _muted


func toggle() -> void:
	_apply(not _muted, true)


## Web 端浏览器音频解锁前 BGM 可能启动失败：首次交互时补启
func resume_bgm() -> void:
	if not _muted and _bgm != null and not _bgm.playing:
		_bgm.play()


func _apply(m: bool, persist: bool) -> void:
	_muted = m
	AudioServer.set_bus_mute(0, m)
	if _btn != null:
		var icon := "icon_sound_off" if m else "icon_sound_on"
		_btn.texture_normal = _load_tex("res://assets/ui/%s.png" % icon)
	if _bgm != null:
		if m:
			_bgm.stop()
		elif not _bgm.playing:
			_bgm.play()
	if persist and OS.has_feature("web"):
		JavaScriptBridge.eval(
			"localStorage.setItem('%s','%s')" % [MUTE_KEY, "1" if m else "0"], true
		)


func _load_muted() -> bool:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("localStorage.getItem('%s') || ''" % MUTE_KEY, true)
		return str(v) == "1"
	return false


## 导出构建中源 .wav 被剔除，必须用 ResourceLoader.exists 走 .import 重映射
func _load_audio(path: String) -> AudioStream:
	if not ResourceLoader.exists(path, "AudioStream"):
		return null
	return load(path) as AudioStream


func _load_tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path, "Texture2D"):
		return null
	return load(path) as Texture2D
