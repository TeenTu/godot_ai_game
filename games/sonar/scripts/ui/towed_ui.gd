class_name TowedUi
extends RefCounted
## towed_ui.gd — 拖曳阵（TOWED）操作胶水（S1-03），从 main_ui 拆出控行数。
##
## main_ui 只把 OperatorPanel 的信号接到此处；世界引用与状态行用 Callable
## 注入。本类不持有任何 UI 控件、不读 Truth，只做「命令转发 + 状态行文案」。

## 世界（只读 own 的 towed 子系统）。
var world: World = null
## Sonar Operator Layer（判断当前是否在使用拖曳阵）。
var op: OperatorSonar = null
## 操作员面板（状态行 + 控件可用性）。
var op_panel: OperatorPanel = null
## 状态行回调：main_ui._update_status。
var status: Callable = Callable()


## 当前 own 的拖曳阵对象（无 world / 无拖曳阵时返回 null）。
func towed_ref() -> TowedArray:
	if world == null:
		return null
	var own: RefCounted = world.world.get("own", null)
	if own == null:
		return null
	return own.get("towed")


func on_deploy() -> void:
	var t: TowedArray = towed_ref()
	if t == null:
		return
	t.stream()
	_notify(UiText.t("st_towed_stream") + " %.0f m" % t.commanded_tow_length_m)


func on_retract() -> void:
	var t: TowedArray = towed_ref()
	if t == null:
		return
	t.retrieve()
	_notify(UiText.t("st_towed_retract"))


func on_hold() -> void:
	var t: TowedArray = towed_ref()
	if t == null:
		return
	t.hold()
	_notify(UiText.t("st_towed_hold") + " %.0f m" % t.actual_tow_length_m)


## S1-03：缆长命令（frac ∈ 0..1 × max_tow_length_m，来自滑条/预设按钮）。
func on_length_commanded(frac: float) -> void:
	var t: TowedArray = towed_ref()
	if t == null:
		return
	t.set_length_command(frac * t.max_tow_length_m)
	_notify(UiText.t("st_towed_cmd") + " %.0f m" % t.commanded_tow_length_m)


## 刷新 TOWED 状态行 + 控件可用性（S1-03；ACT/CMD 分离显示）。
func refresh_status() -> void:
	if op_panel == null:
		return
	var t: TowedArray = towed_ref()
	var on_towed: bool = op != null and op.active_array_id == "TOWED"
	if t == null or not on_towed:
		op_panel.set_towed_status("Towed: n/a", false)
		return
	var line: String = (
		"Towed: %s | ACT %.0fm / CMD %.0fm | arr %.0f° | usable %d%%"
		% [
			t.state_name(),
			t.actual_tow_length_m,
			t.commanded_tow_length_m,
			t.array_heading_deg,
			int(t.usable_fraction() * 100.0),
		]
	)
	op_panel.set_towed_status(line, true)
	op_panel.update_towed_controls(t)


func _notify(msg: String) -> void:
	if status.is_valid():
		status.call(msg)
