class_name PingSessionRules
extends RefCounted

## REQ-B2 抽取：主动 Ping 监听窗/丢弃规则（World._ping_session 纯函数部分）。
## 无状态——session dict 与 sim_time 由调用方传入，便于无头测试。


## 监听是否结束（REQ-04 固定监听窗）： - 窗口（configured_listen_window_s）
## 到期即结束——与登记了多少/多远回波无关，绝不因最远目标 τ 拉长 LISTENING；
## - 窗口内若全部登记回波已提前结算（无超窗残留）也可提前结束。
static func listen_done(session: Dictionary, sim_time: float) -> bool:
	var echoes: Array = session["echoes"]
	if sim_time >= float(session["listen_end_t"]) - 1e-9:
		return true
	if echoes.is_empty():
		return false
	for e in echoes:
		if not bool(e["settled"]):
			return false
	return true


## 监听窗到期：把仍未结算（未到达/超窗）的回波标记为 dropped（不可接收）。
## 它们不得再被结算（settled=true 拦截），也不进入 returned_count/测量流。
static func drop_unsettled(session: Dictionary) -> void:
	var echoes: Array = session["echoes"]
	for e in echoes:
		if bool(e["settled"]):
			continue
		e["settled"] = true
		e["dropped"] = true
		e["detected"] = false
