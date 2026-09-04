class_name SeekerBeamState
extends RefCounted
## seeker_beam_state.gd — 鱼雷 Seeker 扇区单一真源（评审 P0-10）。
##
## 只读数据对象：从武器权威状态（Torpedo + TorpedoAcousticProfile）生成，
## 供 UI（ChartView 扇区绘制）/ 测试读取。物理门（被动采样 / 主动发射 /
## 主动接收）与绘制必须来自同一参数：
##   - 被动/发射/接收半角 = 0.5 * profile.horizontal_beamwidth_deg
##     （TorpedoSensorAdapter 的 _in_fov 门与 schedule_active_echoes 门同源）；
##   - 扇区中心 = 鱼雷**实际**艏向 course_deg（随转率连续转动，绝不跟命令
##     航向瞬移）；
##   - 程序搜索扇区 = 程序快照 search_center_deg/search_half_angle_deg；
##   - tx_state / receiver_state / authority / steering_source 为净化状态
##     字符串（无 Truth）；
##   - display_range_mode = SYMBOLIC：屏幕扇形长度不代表实际探测距离。
## 测试读绘图输入数据（to_dict），断言与适配器本 tick 所用门限一致（AT-19）。

var torpedo_id: String = ""
var center_true_deg: float = 0.0
var passive_half_angle_deg: float = 0.0
var active_tx_half_angle_deg: float = 0.0
var receive_half_angle_deg: float = 0.0
var search_center_true_deg: float = 0.0
var search_half_angle_deg: float = 0.0
var tx_state: String = "OFF"  # OFF / WAITING_TRIGGER / PINGING / COOLDOWN
var receiver_state: String = "PASSIVE_ON"  # PASSIVE_ON / PASSIVE_OFF
var authority: String = "WIRE_ONLY"  # WIRE_ONLY / ASSISTED / AUTONOMOUS
var steering_source: String = "MANUAL_COURSE"  # MANUAL_COURSE / SEARCH_PATTERN / SEEKER_TRACK
var display_range_mode: String = "SYMBOLIC"


static func new_from(tp) -> SeekerBeamState:
	var st := SeekerBeamState.new()
	st.torpedo_id = str(tp.torpedo_id)
	var prof = tp.acoustic_profile
	var half: float = 0.5 * float(prof.horizontal_beamwidth_deg)
	st.passive_half_angle_deg = half
	st.active_tx_half_angle_deg = half
	st.receive_half_angle_deg = half
	# 扇区中心 = 实际艏向（转率限制后的连续值，非命令航向）。
	st.center_true_deg = float(tp.course_deg)
	var prog = tp.program
	st.search_center_true_deg = float(prog.search_center_deg) if prog != null else 0.0
	st.search_half_angle_deg = float(prog.search_half_angle_deg) if prog != null else 0.0
	st.tx_state = str(tp.active_tx_state_name())
	st.receiver_state = "PASSIVE_ON" if bool(tp.passive_receiver_on) else "PASSIVE_OFF"
	st.authority = str(tp.guidance_authority_name())
	st.steering_source = _steering_source(tp)
	return st


func to_dict() -> Dictionary:
	return {
		"torpedo_id": torpedo_id,
		"center_true_deg": center_true_deg,
		"passive_half_angle_deg": passive_half_angle_deg,
		"active_tx_half_angle_deg": active_tx_half_angle_deg,
		"receive_half_angle_deg": receive_half_angle_deg,
		"search_center_true_deg": search_center_true_deg,
		"search_half_angle_deg": search_half_angle_deg,
		"tx_state": tx_state,
		"receiver_state": receiver_state,
		"authority": authority,
		"steering_source": steering_source,
		"display_range_mode": display_range_mode,
	}


## 操舵来源推导（P0-02 优先级：制导 > 线控命令 > 搜索扫掠）：
##   - ATTACK/TERMINAL 且 seeker 有选中航迹 → SEEKER_TRACK；
##   - SEARCH（程序扇区扫掠生效）→ SEARCH_PATTERN；
##   - 其余（WIRE_RUN 线控 / 直航）→ MANUAL_COURSE。
static func _steering_source(tp) -> String:
	var mission: String = str(tp.mission_state_name())
	if mission == "ATTACK" or mission == "TERMINAL":
		if tp._seeker != null and tp._seeker.selected_track() != null:
			return "SEEKER_TRACK"
	if mission == "SEARCH":
		return "SEARCH_PATTERN"
	return "MANUAL_COURSE"
