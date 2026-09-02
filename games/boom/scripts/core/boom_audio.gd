class_name BoomAudio
extends GameKitSfx
## 射击/击中/击杀/受击等手感音效：全部运行时合成 PCM，零素材。
## 在 GameKitSfx 自带音色之上，追加 B-Boom 专用枪声与击杀音。


func _ready() -> void:
	super()
	_bank["shoot"] = _bubble_shot()
	_bank["hit"] = _noise(0.07, 24.0)
	_bank["kill"] = _noise(0.2, 7.0)
	_bank["hurt"] = _sweep(320.0, 110.0, 0.28, 5.0)
	_bank["wave_clear"] = _sweep(500.0, 1400.0, 0.16, 9.0)
	_bank["wave"] = _tone(660.0, 0.09, 9.0)


## 泡泡枪：短促上扫 + 微噪声点击，清脆但不吵。
func _bubble_shot() -> AudioStreamWAV:
	var dur := 0.055
	var n := int(SAMPLE_RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260101
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var freq: float = 680.0 + 300.0 * sin(TAU * 18.0 * t)
		var tone_v: float = sin(TAU * freq * t)
		var click: float = rng.randf_range(-1.0, 1.0) * 0.18
		var env: float = exp(-t * 26.0)
		_write_sample(data, i, (tone_v * 0.9 + click) * env)
	return _wrap(data)
