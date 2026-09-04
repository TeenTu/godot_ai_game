class_name WeaponProgram
extends RefCounted
## weapon_program.gd — 发射前武器编程快照（S1-07 §5.1 / §5.5）。
##
## 发射瞬间生成不可变快照：后续线控命令另记 CommandLog，绝不悄悄改写原始
## 发射程序。本类只是数据 + 校验 + 快照/回退生成，不含任何 Truth 引用、
## 不含传感器/目标选择逻辑。
##
## fire_mode 三态（S1-07 §5.2）：
##   SOLUTION      用 SystemSolution 预填（Track/位置/航向/速度/解龄）；
##   BEARING_ONLY  只要求一个玩家可见 Track/LOB 方位，无距离不得暗中用 Truth；
##   MANUAL        无 Track/解，玩家直接输入航向/深度/主动模式/搜索程序。
##
## 正交解耦（REQ-DECISION-02）：passive 接收机、active 发射机、自主制导、
## 战斗部解保是四件独立的事，各自有独立开关/触发模式，禁止一个 ENABLE_RANGE
## 同时代表全部。

enum FireMode { SOLUTION, BEARING_ONLY, MANUAL }
enum SpeedMode { QUIET, CRUISE, HIGH }
enum SearchPattern { SNAKE, CIRCLE }
enum GuidanceAuthority { WIRE_ONLY, ASSISTED, AUTONOMOUS }
enum ActiveEnableMode { MANUAL, DISTANCE, TIME, WAYPOINT, IMMEDIATE }
enum AutonomyEnableMode { MANUAL, DISTANCE, TIME, WAYPOINT }

const DEPTH_BAND_UPPER: String = "UPPER"
const DEPTH_BAND_LOWER: String = "LOWER"

var program_id: String = ""
var fire_mode: int = FireMode.SOLUTION
var source_track_id: String = ""
var source_solution_version: int = 0

var initial_course_deg: float = 0.0
var speed_mode: int = SpeedMode.CRUISE
var initial_depth_band: String = DEPTH_BAND_UPPER
var search_depth_band: String = DEPTH_BAND_UPPER

var search_center_deg: float = 0.0
var search_half_angle_deg: float = 45.0
var search_pattern: int = SearchPattern.SNAKE

var guidance_authority: int = GuidanceAuthority.WIRE_ONLY
var wire_guidance_enabled: bool = true

var active_enable_mode: int = ActiveEnableMode.MANUAL
var active_enable_distance_m: float = 2000.0
var active_enable_time_s: float = 0.0

var autonomy_enable_mode: int = AutonomyEnableMode.MANUAL
var autonomy_enable_distance_m: float = 3000.0
var autonomy_enable_time_s: float = 0.0

var warhead_arm_distance_m: float = 300.0

## 导线中断后执行的安全回退程序（S1-07 §5.5）。发射前必须有 fallback：
## is_valid() 在 fallback_program == null 时拒绝该程序。
var fallback_program: WeaponProgram = null


## 深拷贝快照（发射时调用；后续对原程序的修改不影响已发射鱼雷）。
func snapshot() -> WeaponProgram:
	var p := WeaponProgram.new()
	p.program_id = program_id
	p.fire_mode = fire_mode
	p.source_track_id = source_track_id
	p.source_solution_version = source_solution_version
	p.initial_course_deg = initial_course_deg
	p.speed_mode = speed_mode
	p.initial_depth_band = initial_depth_band
	p.search_depth_band = search_depth_band
	p.search_center_deg = search_center_deg
	p.search_half_angle_deg = search_half_angle_deg
	p.search_pattern = search_pattern
	p.guidance_authority = guidance_authority
	p.wire_guidance_enabled = wire_guidance_enabled
	p.active_enable_mode = active_enable_mode
	p.active_enable_distance_m = active_enable_distance_m
	p.active_enable_time_s = active_enable_time_s
	p.autonomy_enable_mode = autonomy_enable_mode
	p.autonomy_enable_distance_m = autonomy_enable_distance_m
	p.autonomy_enable_time_s = autonomy_enable_time_s
	p.warhead_arm_distance_m = warhead_arm_distance_m
	p.fallback_program = fallback_program.snapshot() if fallback_program != null else null
	return p


## 程序合法性校验。返回错误数组（空 = 合法）。发射联锁（S1-07 §5.3）：
##   - initial_course 在 0..360；
##   - 深度带合法；
##   - 至少有一个 fallback program（无则生成安全默认）。
func validation_errors() -> Array:
	var errs: Array = []
	if not is_finite(initial_course_deg) or initial_course_deg < 0.0 or initial_course_deg > 360.0:
		errs.append("initial_course out of range")
	if not _valid_band(initial_depth_band):
		errs.append("invalid initial_depth_band")
	if not _valid_band(search_depth_band):
		errs.append("invalid search_depth_band")
	if search_half_angle_deg <= 0.0 or search_half_angle_deg > 180.0:
		errs.append("search_half_angle out of range")
	if warhead_arm_distance_m < 0.0:
		errs.append("warhead_arm_distance negative")
	if fallback_program == null:
		errs.append("missing fallback_program")
	return errs


func is_valid() -> bool:
	return validation_errors().is_empty()


## 生成一个安全的默认 fallback（S1-07 §5.5）：断线后保持最后航向，按预设
## 距离/时间授权自主并开主动，沿 search center 方向继续。仅数据，不含逻辑。
func make_default_fallback() -> WeaponProgram:
	var fb := WeaponProgram.new()
	fb.program_id = program_id + "_FB"
	fb.fire_mode = fire_mode
	fb.source_track_id = source_track_id
	fb.initial_course_deg = search_center_deg
	fb.speed_mode = speed_mode
	fb.initial_depth_band = search_depth_band
	fb.search_depth_band = search_depth_band
	fb.search_center_deg = search_center_deg
	fb.search_half_angle_deg = search_half_angle_deg
	fb.search_pattern = search_pattern
	fb.guidance_authority = GuidanceAuthority.AUTONOMOUS
	fb.wire_guidance_enabled = false
	fb.active_enable_mode = ActiveEnableMode.DISTANCE
	fb.active_enable_distance_m = maxf(active_enable_distance_m, 100.0)
	fb.autonomy_enable_mode = AutonomyEnableMode.DISTANCE
	fb.autonomy_enable_distance_m = maxf(autonomy_enable_distance_m, 100.0)
	fb.warhead_arm_distance_m = warhead_arm_distance_m
	return fb


static func _valid_band(b: String) -> bool:
	return b == DEPTH_BAND_UPPER or b == DEPTH_BAND_LOWER


## UI/日志用：speed_mode / fire_mode / 深度带等转可读字符串。
static func fire_mode_name(m: int) -> String:
	match m:
		FireMode.BEARING_ONLY:
			return "BEARING_ONLY"
		FireMode.MANUAL:
			return "MANUAL"
	return "SOLUTION"


static func speed_mode_name(m: int) -> String:
	match m:
		SpeedMode.QUIET:
			return "QUIET"
		SpeedMode.HIGH:
			return "HIGH"
	return "CRUISE"
