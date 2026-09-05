class_name TorpedoDepthControl
extends RefCounted
## torpedo_depth_control.gd — 鱼雷垂向/层带控制子模块（从 torpedo.gd 拆出）。
##
## 职责（S1-07A 深度模型 + REQ-DEP-01/02）：
##   - 显式定深写入与钳制（模型 surface/bottom 限制；命令与实际分离）；
##   - 层带 hold 解析与 UPPER↔LOWER 双向层带命令（有限垂速执行）；
##   - 垂直运动积分 z_next = z + clamp(z_cmd - z, -Vz·dt, +Vz·dt)；
##   - 全自动换带搜索（AUTO 依次换带，保持超时/燃料约束）。
## 本类不持有 Torpedo 引用（避免 RefCounted 环）——所有方法显式传 tp；
## 读写均经 Torpedo 公开字段（explicit_depth_m/commanded_depth_m/actual_depth_m
## /depth_state/command_log 等），绝不触碰 Truth。

var _band_hold_reached_t: float = -1.0  # 层带保持起点（换带搜索计时；<0 未到）
var _band_switch_count: int = 0  # 换带次数（诊断/日志）


## 内部深度带命令（不经过线控门；fallback/程序自执行用）。
func command_band_internal(tp: RefCounted, band: String) -> bool:
	if band != WeaponProgram.DEPTH_BAND_UPPER and band != WeaponProgram.DEPTH_BAND_LOWER:
		return false
	tp.commanded_depth_band = band
	_band_hold_reached_t = -1.0  # 新层带命令重置保持计时
	set_explicit(tp, hold_depth_for_band(tp, band), true)
	return true


## REQ-01：显式定深写入（钳制到模型可用范围；命令与实际分离）。
func set_explicit(tp: RefCounted, depth_m: float, from_band: bool = false) -> void:
	var z_min: float = tp.min_depth_m
	var z_max: float = tp.max_depth_m
	var dm: Variant = tp._depth_model
	if dm != null:
		z_min = float(dm.get("surface_depth_m"))
		z_max = float(dm.get("bottom_depth_m"))
	var z: float = clampf(depth_m, z_min, z_max)
	tp.explicit_depth_m = z
	tp._explicit_from_band = from_band
	tp.commanded_depth_m = z
	_band_hold_reached_t = -1.0  # 新命令重置换带搜索保持计时
	if z > tp.actual_depth_m + 0.5:
		tp.depth_state = tp.DepthState.DIVING
	elif z < tp.actual_depth_m - 0.5:
		tp.depth_state = tp.DepthState.CLIMBING
	else:
		tp.depth_state = tp.DepthState.HOLDING_UPPER


## REQ-DEP-02：换带搜索。当前搜索带保持超时且仍无航迹时切到另一层带
## （有限垂速由 advance_vertical 保证；UPPER↔LOWER 双向）；显式定深
## （PLAYER/PROGRAM SURFACE/CUSTOM）绝不参与换带，不被静默覆盖。
func maybe_switch_search_band(tp: RefCounted, sim_time: float) -> void:
	if (
		not tp.band_search_enabled
		or tp.explicit_depth_m >= 0.0
		or tp.commanded_depth_band == ""
		or _band_hold_reached_t < 0.0
		or sim_time - _band_hold_reached_t < tp.band_search_hold_s
	):
		return
	if tp.fuel_left_s < 60.0:  # 燃料约束：余量不足以完成下一带搜索
		return
	var other: String = (
		WeaponProgram.DEPTH_BAND_LOWER
		if tp.commanded_depth_band == WeaponProgram.DEPTH_BAND_UPPER
		else WeaponProgram.DEPTH_BAND_UPPER
	)
	_band_switch_count += 1
	command_band_internal(tp, other)
	tp.depth_command_source = "AUTO"
	tp._log_command("BAND_SEARCH_SWITCH", {"to_band": other, "visits": _band_switch_count})
	tp.event_occurred.emit(tp.torpedo_id, "BAND_SEARCH_SWITCH", {"to_band": other})


## 垂直运动：z 按 Vz_max 速率逼近命令深度（模型钳制）。REQ-01：显式定深
## 到达后持续保持（防层带提示回拉）。
func advance_vertical(tp: RefCounted, dt: float) -> void:
	if tp.commanded_depth_m < 0.0:
		return
	var z_min: float = tp.min_depth_m
	var z_max: float = tp.max_depth_m
	var dm: Variant = tp._depth_model
	if dm != null:
		z_min = float(dm.get("surface_depth_m"))
		z_max = float(dm.get("bottom_depth_m"))
	var dz: float = clampf(
		tp.commanded_depth_m - tp.actual_depth_m,
		-tp.max_vertical_speed_m_s * dt,
		tp.max_vertical_speed_m_s * dt
	)
	tp.actual_depth_m = clampf(tp.actual_depth_m + dz, z_min, z_max)
	if absf(tp.commanded_depth_m - tp.actual_depth_m) < 0.5:
		tp.actual_depth_m = tp.commanded_depth_m
		tp.depth_state = depth_state_for_band(tp, band_label_for_depth(tp, tp.actual_depth_m))
		if tp.explicit_depth_m < 0.0 or tp._explicit_from_band:  # hold 到达即释放
			if tp._explicit_from_band:
				tp.explicit_depth_m = -1.0
				tp._explicit_from_band = false
			tp.commanded_depth_m = -1.0
			# REQ-DEP-02：层带保持起点（换带搜索计时用；显式定深不参与换带）。
			_band_hold_reached_t = tp._sim_time


## 按深度求层带标签（UPPER/LOWER）。
func band_label_for_depth(tp: RefCounted, z_m: float) -> String:
	var dm: Variant = tp._depth_model
	if dm != null and dm.has_method("depth_band"):
		var b: String = str(dm.call("depth_band", z_m))
		if b == WeaponProgram.DEPTH_BAND_LOWER:
			return WeaponProgram.DEPTH_BAND_LOWER
		return WeaponProgram.DEPTH_BAND_UPPER
	return (
		WeaponProgram.DEPTH_BAND_LOWER
		if z_m >= tp.DEFAULT_LOWER_HOLD_DEPTH_M
		else WeaponProgram.DEPTH_BAND_UPPER
	)


func hold_depth_for_band(tp: RefCounted, band: String) -> float:
	var dm: Variant = tp._depth_model
	if dm != null and dm.has_method("hold_depth_for_band"):
		return float(dm.call("hold_depth_for_band", band))
	if band == WeaponProgram.DEPTH_BAND_LOWER:
		return tp.DEFAULT_LOWER_HOLD_DEPTH_M
	return tp.DEFAULT_UPPER_HOLD_DEPTH_M


func depth_state_for_band(tp: RefCounted, band: String) -> int:
	if band == WeaponProgram.DEPTH_BAND_LOWER:
		return tp.DepthState.HOLDING_LOWER
	return tp.DepthState.HOLDING_UPPER
