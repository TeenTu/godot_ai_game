class_name WireLink
extends RefCounted
## wire_link.gd — 线导链路（S1-07 §5.4，Commit 4）。
##
## 纯数据 + 确定性逻辑，无 Truth、无传感器、无母艇引用。放线长度按鱼雷
## 对地速度每 tick 累计（paid_out_m），超过 max_length_m 且
## break_on_excess_length=true 时确定性 CONNECTED→BROKEN（§5.4：首版用
## 长度/配置条件确定性断线，不用随机断线，方便理解与测试）。
##
## 命令门（§5.4）：仅 enabled 且 state==CONNECTED 时 accepts_commands()==true；
## BROKEN/CUT 后拒绝新命令，由调用方（Torpedo）给出明确原因。
## 导线不回传 Truth：本类不含任何目标/测量数据。
##
## 状态（与 §3.6 WireState 对应，顺序固定）：
##   CONNECTED / BROKEN / CUT
## launcher_turn_limit_deg_s / launcher_speed_limit_kn 为母艇机动极限导致的断线
## 预留配置（需要母艇状态，后移）；本轮只实现长度断线 + 主动 cut。

enum State { CONNECTED, BROKEN, CUT }

const DEFAULT_MAX_LENGTH_M: float = 30000.0

var enabled: bool = true
var state: int = State.CONNECTED
var max_length_m: float = DEFAULT_MAX_LENGTH_M
var paid_out_m: float = 0.0
var command_latency_s: float = 0.0
var break_on_excess_length: bool = true
var launcher_turn_limit_deg_s: float = 0.0
var launcher_speed_limit_kn: float = 0.0


## 复位到出厂默认（发射时调用）。
func reset() -> void:
	enabled = true
	state = State.CONNECTED
	max_length_m = DEFAULT_MAX_LENGTH_M
	paid_out_m = 0.0
	command_latency_s = 0.0
	break_on_excess_length = true
	launcher_turn_limit_deg_s = 0.0
	launcher_speed_limit_kn = 0.0


## 从配置字典覆盖字段（场景/程序可注入；未给出的键保持现值）。
func configure(cfg: Dictionary) -> void:
	enabled = bool(cfg.get("enabled", enabled))
	state = int(cfg.get("state", state))
	max_length_m = float(cfg.get("max_length_m", max_length_m))
	paid_out_m = float(cfg.get("paid_out_m", paid_out_m))
	command_latency_s = float(cfg.get("command_latency_s", command_latency_s))
	break_on_excess_length = bool(cfg.get("break_on_excess_length", break_on_excess_length))
	launcher_turn_limit_deg_s = float(
		cfg.get("launcher_turn_limit_deg_s", launcher_turn_limit_deg_s)
	)
	launcher_speed_limit_kn = float(cfg.get("launcher_speed_limit_kn", launcher_speed_limit_kn))


func is_wire_connected() -> bool:
	return enabled and state == State.CONNECTED


## 线控命令门：仅连接中可收新命令（§5.4 BROKEN/CUT 后拒绝）。
func accepts_commands() -> bool:
	return is_wire_connected()


func state_name() -> String:
	match state:
		State.BROKEN:
			return "BROKEN"
		State.CUT:
			return "CUT"
	return "CONNECTED"


## 每 tick 放线：按鱼雷对地速度累计放出长度。返回 true 表示本 tick 内发生
## CONNECTED→BROKEN（超长确定性断线）；非连接态直接返回 false。
func update(dt: float, speed_m_s: float) -> bool:
	if not is_wire_connected():
		return false
	paid_out_m += maxf(speed_m_s, 0.0) * dt
	if break_on_excess_length and paid_out_m > max_length_m:
		state = State.BROKEN
		return true
	return false


## 玩家主动切断（§5.4 CUT_WIRE）：仅 CONNECTED 可切，返回是否成功。
func cut() -> bool:
	if not is_wire_connected():
		return false
	state = State.CUT
	return true


## 外部强制断线（超长以外的确定性断线入口，如配置/测试），仅 CONNECTED 可断。
func break_wire() -> bool:
	if not is_wire_connected():
		return false
	state = State.BROKEN
	return true
