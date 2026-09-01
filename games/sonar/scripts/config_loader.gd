extends RefCounted
class_name ConfigLoader
## config_loader.gd — 从 JSON 加载参数/场景。
## 所有声学、传感器、平台参数都在 JSON 资源文件里，不写死在业务代码。

static func load_json_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("config_loader: 无法打开文件 " + path)
		return {}
	var text: String = f.get_as_text()
	f.close()
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("config_loader: JSON 解析失败 " + path + " : " + json.get_error_message())
		return {}
	if not (json.data is Dictionary):
		push_error("config_loader: 顶层必须是对象 " + path)
		return {}
	return json.data


## 便捷：加载 scenario 目录下的某个场景。
static func load_scenario(scenario_name: String) -> Dictionary:
	# 场景 JSON 放在 res://tools/scenarios/ 下（随工程一起导出，CI 可无头加载）
	return load_json_file("res://tools/scenarios/" + scenario_name + ".json")
