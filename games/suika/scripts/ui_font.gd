class_name UiFont
extends RefCounted

## 项目里自绘文字（水果名字、合成飘分）统一走这里取字体。
## Web 导出拿不到系统字体，必须用它内置的中文子集字体，否则出豆腐块。

const FONT_PATH: String = "res://assets/fonts/ui_subset.ttf"

static var _cached: Font = null


static func get_font() -> Font:
	if _cached == null:
		if ResourceLoader.exists(FONT_PATH):
			_cached = load(FONT_PATH)
		else:
			_cached = ThemeDB.fallback_font
	return _cached
