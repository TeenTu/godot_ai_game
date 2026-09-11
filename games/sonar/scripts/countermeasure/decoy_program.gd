class_name DecoyProgram
extends RefCounted

## DecoyProgram（S1-07 §8.3，Commit 8；P1-C DC-02/DC-03）：单枚诱饵的发射程序。
## 发射瞬间生成不可变快照（snapshot()），实际部署的诱饵只读快照字段。
##
## DC-02（单一主要方向）：普通 UI 只保留"投放方向（真方位）"launch_bearing_deg。
## `course_deg < 0` = **未设置**独立巡航方向 → 诱饵沿投放方向分离并继续航行。
## 旧默认 `course_deg = 0.0`（正北）会静默覆盖玩家选的投放方向，已删除。
## 只有显式设置 `course_deg >= 0` 才算"高级独立巡航方向"，UI 必须标注（见
## is_advanced_course()），且发射后快照固定——本艇后续命令不再作用于诱饵。
##
## DC-03（有限出管分离）：JAMMER 不再全程 0 节（方向因此无效）。分离阶段用
## separation_speed_kn + separation_duration_s 产生**真实有限位移**（数十米量级，
## 配置化，不宣称真实装置射程），随后降到 speed_kn（漂浮/低速）。

const TYPE_MOBILE := "MOBILE_DECOY"
const TYPE_JAMMER := "JAMMER_CONFUSER"

## DC-02：未设置独立巡航方向（跟随投放方向）。
const COURSE_FOLLOW_LAUNCH: float = -1.0
## DC-03：未设置分离速度（回落到 speed_kn，即无分离阶段差异）。
const SEPARATION_UNSET: float = -1.0

var launcher_id: String = "CM-1"
var decoy_type: String = TYPE_MOBILE
var launch_bearing_deg: float = 0.0
var initial_depth_band: String = WeaponProgram.DEPTH_BAND_UPPER
var commanded_depth_band: String = WeaponProgram.DEPTH_BAND_UPPER
## 出管后**高级**独立巡航航向（MOBILE 用）；默认跟随投放方向（DC-02）。
var course_deg: float = COURSE_FOLLOW_LAUNCH
## 分离阶段结束后的巡航/漂浮速度（MOBILE 巡航；JAMMER 近静止）。
var speed_kn: float = 8.0
## 分离阶段速度与持续时间（DC-03）；duration=0 表示没有分离阶段。
var separation_speed_kn: float = SEPARATION_UNSET
var separation_duration_s: float = 0.0
var activation_delay_s: float = 2.0  # 出舱到声学激活的延时（不阻止出管后的运动）
var lifetime_s: float = 120.0  # 有限寿命（§8.6）
##  signature：诱饵声学画像（AcousticProfile 或可 from_dict 的字典）。
##  MOBILE 模拟目标谱（稳定谱线）；JAMMER 宽带高噪 + 不稳定假峰（运行时抖动）。
var signature: RefCounted = null
var signature_profile_id: String = "default"


func snapshot() -> DecoyProgram:
	var p := DecoyProgram.new()
	p.launcher_id = launcher_id
	p.decoy_type = decoy_type
	p.launch_bearing_deg = launch_bearing_deg
	p.initial_depth_band = initial_depth_band
	p.commanded_depth_band = commanded_depth_band
	p.course_deg = course_deg
	p.speed_kn = speed_kn
	p.separation_speed_kn = separation_speed_kn
	p.separation_duration_s = separation_duration_s
	p.activation_delay_s = activation_delay_s
	p.lifetime_s = lifetime_s
	p.signature = signature
	p.signature_profile_id = signature_profile_id
	return p


## DC-02：实际使用的出管航向——未设独立巡航方向时就是投放方向。
func resolved_course_deg() -> float:
	if course_deg < 0.0:
		return NavUtils.wrap360(launch_bearing_deg)
	return NavUtils.wrap360(course_deg)


## DC-02：是否使用了与投放方向不同的高级独立巡航方向（UI 需显式标注为"高级"）。
func is_advanced_course() -> bool:
	if course_deg < 0.0:
		return false
	return absf(NavUtils.wrap180(course_deg - launch_bearing_deg)) > 0.5


## DC-03：分离速度（未设置 → 回落到 speed_kn）。
func resolved_separation_speed_kn() -> float:
	if separation_speed_kn < 0.0:
		return speed_kn
	return separation_speed_kn


## 是否有真实分离阶段（速度/持续时间都有意义）。
func has_separation_phase() -> bool:
	return separation_duration_s > 0.0 and absf(resolved_separation_speed_kn() - speed_kn) > 0.01


## 合法性（§8.5 发射条件的数据面 + P1-C 新增字段）。
func validate() -> Array:
	var errs: Array = []
	if decoy_type != TYPE_MOBILE and decoy_type != TYPE_JAMMER:
		errs.append("decoy_type unknown")
	if launch_bearing_deg < 0.0 or launch_bearing_deg >= 360.0:
		errs.append("launch_bearing out of range")
	if course_deg >= 360.0 or course_deg < COURSE_FOLLOW_LAUNCH:
		errs.append("course out of range")
	if speed_kn < 0.0 or speed_kn > 30.0:
		errs.append("speed_kn out of range")
	if separation_speed_kn > 30.0 or separation_speed_kn < SEPARATION_UNSET:
		errs.append("separation speed out of range")
	if separation_duration_s < 0.0:
		errs.append("separation duration negative")
	if activation_delay_s < 0.0:
		errs.append("activation_delay negative")
	if lifetime_s <= 0.0:
		errs.append("lifetime must be positive")
	if separation_duration_s > lifetime_s:
		errs.append("separation longer than lifetime")
	return errs
