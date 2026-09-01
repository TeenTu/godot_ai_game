class_name GameKitSfx
extends Node
## 程序化音效发生器：运行时合成 PCM 波形，不依赖任何音频素材文件。
##
## 用法：把本节点加进场景（每场景一个），然后 play("pickup") 等按名播放。
## 每次播放临时创建 AudioStreamPlayer，播完自毁，支持重叠播放。
## 浏览器自动播放策略：首次发声需发生在用户交互之后（Godot Web 端会自动恢复
## AudioContext），所以别在 _ready 里直接播放。
##
## 内置音色：blip(短滴) / pickup(上滑) / graze(高音闪) / boom(爆裂) / over(下坠)。
## 想自定义：在 _ready 里往 _bank 塞自己的 AudioStreamWAV 即可。

const SAMPLE_RATE: int = 22050

var _bank: Dictionary = {}


func _ready() -> void:
	_bank["blip"] = _tone(880.0, 0.09, 5.0)
	_bank["pickup"] = _sweep(520.0, 1040.0, 0.16, 4.0)
	_bank["graze"] = _tone(1320.0, 0.06, 7.0)
	_bank["boom"] = _noise(0.32, 9.0)
	_bank["over"] = _sweep(440.0, 110.0, 0.7, 2.2)


## 按名播放一个音效；volume_db 负值更轻。
func play(sound_name: String, volume_db: float = 0.0) -> void:
	if not _bank.has(sound_name):
		push_warning("GameKitSfx: unknown sound '%s'" % sound_name)
		return
	var p := AudioStreamPlayer.new()
	p.stream = _bank[sound_name]
	p.volume_db = volume_db
	p.finished.connect(p.queue_free)
	add_child(p)
	p.play()


## 纯正弦短音：freq 频率，dur 时长，decay 越大衰减越快。
func _tone(freq: float, dur: float, decay: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var env: float = exp(-t * decay)
		_write_sample(data, i, sin(TAU * freq * t) * env)
	return _wrap(data)


## 频率从 f0 滑到 f1 的扫频音。
func _sweep(f0: float, f1: float, dur: float, decay: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var k: float = t / dur
		phase += TAU * lerpf(f0, f1, k) / SAMPLE_RATE
		_write_sample(data, i, sin(phase) * exp(-t * decay))
	return _wrap(data)


## 白噪声爆裂：爆炸/碎盾。
func _noise(dur: float, decay: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260901
	var last := 0.0
	for i in n:
		var t := float(i) / SAMPLE_RATE
		# 一阶低通让噪声听起来闷一点，更像撞击而不是电流。
		last = last * 0.6 + rng.randf_range(-1.0, 1.0) * 0.4
		_write_sample(data, i, last * exp(-t * decay))
	return _wrap(data)


func _write_sample(data: PackedByteArray, i: int, v: float) -> void:
	var s := int(clampf(v, -1.0, 1.0) * 32767.0)
	data[i * 2] = s & 0xFF
	data[i * 2 + 1] = (s >> 8) & 0xFF


func _wrap(data: PackedByteArray) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = data
	return wav
