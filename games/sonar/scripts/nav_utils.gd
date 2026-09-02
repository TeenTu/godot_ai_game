class_name NavUtils
extends RefCounted
## nav_utils.gd — 导航 / 角度 / 坐标 / 速度换算的纯函数库。
##
## 全项目唯一的数学换算入口，杜绝"数学坐标系(从东逆时针)"与"海军坐标系(从北顺时针)"混用。
## 所有函数都是纯函数（无状态），可无头单测。
##
## 约定（全局唯一）：
##   - x 向东，y 向北（二维笛卡尔，米）
##   - 航向/方位：正北 0°，顺时针增加，归一化 [0,360)
##   - 方位残差归一化到 [-180,180)
##   - 速度：内部用 m/s，显示用节（1 kn = 0.514444 m/s）

const KNOT_TO_MS: float = 0.514444
const DEG_TO_RAD: float = 0.017453292519943295
const RAD_TO_DEG: float = 57.29577951308232


## 把角度归一化到 [0,360)
static func wrap360(deg: float) -> float:
	var d: float = fmod(deg, 360.0)
	if d < 0.0:
		d += 360.0
	return d


## 把角度差归一化到 [-180,180) 的"有符号"残差（用于方位残差）。
static func wrap180(deg: float) -> float:
	var d: float = wrap360(deg)
	if d >= 180.0:
		d -= 360.0
	return d


## 两个角度的有符号差（a - b），归一化到 [-180,180)。
## 例：wrap180(10 - 350) = 20（从 350° 到 10° 是顺时针 +20°）。
static func angle_diff(a_deg: float, b_deg: float) -> float:
	return wrap180(a_deg - b_deg)


## 节 → 米/秒
static func kn_to_ms(kn: float) -> float:
	return kn * KNOT_TO_MS


## 米/秒 → 节
static func ms_to_kn(ms: float) -> float:
	return ms / KNOT_TO_MS


## 从本艇(o)看目标(t)的真实方位（海军方位，从北顺时针，0~360）。
## 输入为各自笛卡尔位置（米）。
static func bearing_to_true(o_east: float, o_north: float, t_east: float, t_north: float) -> float:
	var dx: float = t_east - o_east
	var dy: float = t_north - o_north
	# atan2(dx, dy)：x 是"东"，y 是"北"，结果天然就是"从北顺时针"。
	return wrap360(atan2(dx, dy) * RAD_TO_DEG)


## 两点间水平距离（米）。
static func distance(o_east: float, o_north: float, t_east: float, t_north: float) -> float:
	var dx: float = t_east - o_east
	var dy: float = t_north - o_north
	return sqrt(dx * dx + dy * dy)


## 根据航向(deg, 从北顺时针)和航速(m/s)推进位置，返回 {x,y}。
static func advance_pos(
	x: float, y: float, course_deg: float, speed_ms: float, dt: float
) -> Dictionary:
	var rad: float = course_deg * DEG_TO_RAD
	return {
		"x": x + speed_ms * sin(rad) * dt,
		"y": y + speed_ms * cos(rad) * dt,
	}


# ------------------------------------------------------------------
# 统一方位系（声呐综合修复 问题2）：
#   真方位 true_bearing     = wrap360(atan2(ΔE,ΔN))             —— Measurement/Track/TMA 内部使用
#   显示方位 display_bearing = wrap180(true - own_course)          —— 艇艏相对瀑布图（艇艏=0°）
#   阵列方位 array_bearing   = wrap180(true - array_heading)       —— 阵列覆盖与方向增益
# BOW/FLANK 的 array_heading = own.course；TOWED 用独立滞后航向。
# ------------------------------------------------------------------


## 相对方位 → 真方位：βtrue = wrap360(ψown + βrel)。
static func rel_to_true(own_course_deg: float, rel_deg: float) -> float:
	return wrap360(own_course_deg + rel_deg)


## 真方位 → 艇艏相对显示方位：βdisp = wrap180(βtrue − ψown)。
static func true_to_display(own_course_deg: float, true_deg: float) -> float:
	return wrap180(true_deg - own_course_deg)


## 真方位 → 阵列相对方位：βarray = wrap180(βtrue − ψarray)。
static func true_to_array(array_heading_deg: float, true_deg: float) -> float:
	return wrap180(true_deg - array_heading_deg)


## 判断某阵列方位是否落在若干扇区内（扇区边界取相对该阵列 0..360）。
## sectors: Array[Vector2]，每个 (start,end) 逆时针跨弧。
static func in_sectors(array_rel_deg: float, sectors: Array) -> bool:
	var a: float = fposmod(array_rel_deg, 360.0)
	for s in sectors:
		var a0: float = fposmod(float(s.x), 360.0)
		if fposmod(a - a0, 360.0) <= fposmod(float(s.y) - a0, 360.0):
			return true
	return false


## 单个覆盖扇区的方向性增益（dB）：离开扇区中心角度差 Δ（度），
## 增益按余弦状衰减。beam_halfwidth_deg 为半宽。
static func sector_gain_db(
	array_rel_deg: float, center_rel_deg: float, beam_halfwidth_deg: float
) -> float:
	var d: float = absf(wrap180(array_rel_deg - center_rel_deg))
	if d <= beam_halfwidth_deg:
		return 0.0
	# 超出扇区边缘：每超过 1° 衰减 0.5 dB，平滑而非硬切
	return -0.5 * (d - beam_halfwidth_deg)
