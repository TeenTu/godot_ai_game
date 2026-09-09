class_name UiText
extends RefCounted
## ui_text.gd — S109 §10 集中中文文案目录 + 内部枚举 → 显示映射。
##
## 纪律（§10.2）：内部枚举、序列化键、比较判断一律保持英文；本文件只做
## 「显示层」映射，业务代码禁止比较中文字符串。缺键时原样返回并在
## `missing_keys` 计数（zh_cn_ui_test AT-35 要求计数为 0）。
## 默认语言 zh_CN：英文键 → 中文值（§10.4 集中翻译键）。
const _MODE := {"MANUAL": "手动", "ASSISTED": "辅助", "FULL_AUTO": "全自动"}

const _ASSOC := {"LOCKED": "锁定当前组", "SUGGEST": "建议关联", "AUTO": "自动关联"}

const _PING := {
	"READY": "就绪",
	"TRANSMITTING": "脉冲发射中",
	"LISTENING": "监听回波",
	"RETURN": "收到回波",
	"NO_RETURN": "未收到回波",
	"NO RETURN": "未收到回波",
	"COOLDOWN": "冷却中",
	"UNAVAILABLE": "无主动声呐",
}

const _THREAT := {
	"TENTATIVE": "暂定威胁",
	"TRACKING": "正在跟踪",
	"RANGE_AIDED": "主动测距辅助",
	"COASTING": "外推中",
	"LOST": "已失联",
}

const _MISSION := {
	"RUNNING": "任务进行中",
	"PLAYER_DEFEATED": "任务失败",
	"MISSION_ENDED": "任务已结束",
	"TORPEDO_HIT": "鱼雷命中，本艇损失",
}

const _CLASS := {
	"UNCLASSIFIED": "未分类",
	"SUSPECTED_TORPEDO": "疑似鱼雷",
	"PROBABLE_TORPEDO": "高概率鱼雷",
	"POSSIBLE_TORPEDO": "疑似鱼雷",
	"TORPEDO_ACTIVE_PING": "鱼雷主动脉冲",
	"SUBMARINE": "潜艇",
	"DECOY": "诱饵",
	"UNKNOWN": "未知",
}

## 武器事件 / 证据种类 / 告警分级（alert_panel、weapon_panel、in_water 面板共用）
const _EVENT := {
	"POSSIBLE_TORPEDO": "疑似鱼雷",
	"PROBABLE_KILL": "可能击沉",
	"PROBABLE_HIT": "可能命中",
	"POSSIBLE_KILL": "疑似击沉",
	"NO_DAMAGE": "无损伤",
	"MISS": "未命中",
	"DETONATION": "起爆",
	"TORPEDO_LAUNCH": "鱼雷发射",
	"LAUNCH_TRANSIENT": "发射瞬态",
	"RUNNING_NOISE": "持续噪声",
	"ACTIVE_PING": "主动脉冲",
	"ACTIVE_RETURN": "主动回波",
	"TORPEDO_NOISE": "鱼雷噪声",
	"JAMMING": "施放干扰",
	"DECOY_LAUNCHED": "诱饵发射",
	"SEEKER_PHASE": "导引头阶段",
	"TRACK_ACCEPTED": "截获目标",
	"ACTIVE_TX_PING": "主动发射",
	"ECHO_RECEIVED": "收到回波",
	"LISTEN_COMPLETE_NO_RETURN": "监听结束无回波",
	"FUZE_ARMED": "引信解除保险",
	"LOST": "已失联",
	"CONTACT": "接触",
	"INFO": "信息",
	"TRANSIENT": "瞬态",
}

## 鱼雷 mission_state（Torpedo.mission_state_name()）
const _TP_STATE := {
	"STOWED": "在库",
	"LAUNCHING": "发射中",
	"WIRE_RUN": "线导航行",
	"SEARCH": "搜索",
	"ATTACK": "攻击",
	"TERMINAL": "末段",
	"DEAD": "终止",
}

## 导引头阶段（Torpedo.SeekerState）
const _SEEKER := {
	"PASSIVE_LISTEN": "被动监听",
	"ACTIVE_SEARCH": "主动搜索",
	"COMBINED_SEARCH": "主被动搜索",
	"ACQUIRING": "截获中",
	"TRACKING": "跟踪",
	"COAST": "滑行",
	"LOST": "已失联",
	"REACQUIRE": "重新截获",
}

## 主动发射机状态
const _TX := {
	"OFF": "关机",
	"WAITING_TRIGGER": "待发",
	"PINGING": "发射中",
	"COOLDOWN": "冷却中",
}

## 制导权限
const _AUTH := {"WIRE_ONLY": "仅线导", "ASSISTED": "辅助", "AUTONOMOUS": "自主"}

## 转向来源
const _STEER := {
	"MANUAL_COURSE": "人工航向",
	"SEARCH_PATTERN": "搜索模式",
	"SEEKER_TRACK": "导引头航迹",
}

## 速度模式
const _SPEEDMODE := {"QUIET": "静音", "CRUISE": "巡航", "HIGH": "高速"}

## 深度指令来源
const _SRC := {"PLAYER": "玩家", "PROGRAM": "程序", "AUTO": "自动"}

## 脱靶根因
const _MISS := {"FUEL_EXHAUSTED": "燃料耗尽"}

## 搜索深度预设 / 层带（WeaponProgram.SearchDepthPreset & DEPTH_BAND_*）
const _DEPTHPRESET := {
	"SURFACE": "海面层",
	"UPPER": "上层",
	"LOWER": "下层",
	"CUSTOM": "定制深度",
}

## 搜索图案（WeaponProgram.SearchPattern）
const _PATTERN := {"SNAKE": "蛇形搜索", "CIRCLE": "环形搜索"}

## 主动开机/自治授权条件（ActiveEnableMode / AutonomyEnableMode）
const _ENMODE := {
	"MANUAL": "手动",
	"DISTANCE": "按距离",
	"TIME": "按时长",
	"WAYPOINT": "按航路点",
	"IMMEDIATE": "立即",
}

## 引信模式（FuzeController.FUZE_*）
const _FUEZEMODE := {
	"CONTACT": "接触引信",
	"ACOUSTIC_PROXIMITY": "声近炸",
	"MAGNETIC_PROXIMITY": "磁近炸",
}

## 引信状态（Torpedo.FuzeState）
const _FUEZESTATE := {
	"SAFE": "保险",
	"ARMED": "解保",
	"TRIGGERED": "已触发",
	"INERT": "惰性",
}

## 基阵显示名
const _ARRAY := {"BOW": "艇艏阵", "SIDE": "舷侧阵", "TOWED": "拖曳阵"}

## 主动声呐参数模式
const _PINGMODE := {"Single pulse": "单脉冲"}

## 暴露等级（前缀匹配）
const _EXPO := {
	"HIGH": "高 — 敌可能截获",
	"MEDIUM": "中",
	"MED": "中",
	"LOW": "低",
}

## 自动化 ROE 开关键名
const _ROE := {"auto_fire": "自动发射", "auto_decoy": "自动诱饵"}

## 诱饵类型（DecoyProgram.TYPE_*）
const _DECOY := {"MOBILE_DECOY": "机动诱饵", "JAMMER_CONFUSER": "干扰器"}

## 线导状态
const _WIRE := {
	"CONNECTED": "已连接",
	"CUT": "已切断",
	"BROKEN": "已断裂",
	"NONE": "无导线",
}

const _FIRE_MODE := {
	"SOLUTION": "按系统解算",
	"BEARING_ONLY": "仅方位",
	"MANUAL": "手动",
}

## 告警分组（alert_panel REQ-UI-04）
const _GROUP := {"THREAT": "威胁", "CM": "反制", "BDA": "战果", "INFO": "信息"}

## 被动接收机开/关（in_water 面板）
const _RX := {"PASSIVE_ON": "被动开", "PASSIVE_OFF": "被动关"}

## TMA 拟合结果状态（tma_solver / chart fit_status）。
const _FIT := {
	"CONVERGED": "已收敛",
	"PROVISIONAL": "暂定解",
	"AMBIGUOUS_LR": "左右舷模糊",
	"MULTIMODAL": "多峰解",
	"MANEUVER_SUSPECTED": "疑似目标机动",
	"INSUFFICIENT_MEASUREMENTS": "测量不足",
	"INSUFFICIENT_GEOMETRY": "几何不足",
	"BOUNDARY_HIT": "触及边界",
	"STALE": "已过期",
	"NO_DATA": "无数据",
	"NO_FIT": "未拟合",
	"NONE": "无",
	"?": "?",
	"AWAITING APPLY": "待应用距离证据",
	"REFIT REQUIRED": "需要重新拟合",
	"RANGE AIDED": "测距辅助",
	"REJECTED": "已拒绝",
}

## 火控/提交拒绝原因（fire_executor / system solution）。
const _SUBMIT := {
	"FIT_STALE": "拟合已过期",
	"FIT_VERSION_GONE": "拟合版本已失效",
	"NO_TRIAL": "缺少试拟解",
	"OWN_SIDE": "目标在本艇同一阵营",
	"TRIAL_TRACK_MISMATCH": "试拟解与目标不匹配",
	"AUTONOMY_AUTHORIZED": "自主授权不允许",
	"AUTONOMY_ENABLED": "自动化未启用",
	"FALLBACK": "回退拒绝",
	"RANGE_INVALID": "距离无效",
	"SEEKER_LOST": "导引头已丢失",
}

const _REJECT := {
	"INVALID DEPTH": "深度指令非法",
	"NO CANDIDATE": "无有效目标候选",
	"LAUNCHING": "鱼雷仍在发射中",
	"MISSION_ENDED": "任务已结束：命令被拒",
	"INVALID TRANSITION": "非法状态转换",
}

## 静态 UI 文案目录（英文键 → 中文显示，S109 §10.4）。
const LABELS := {
	# ---- 主界面 / 右栏分页 ----
	"app_title": "潜艇声呐 / 目标运动分析（TMA）",
	"pause": "‖ 暂停",
	"resume": "‖ 继续",
	"speed": "倍速",
	"selected_none": "选中：无",
	"selected_prefix": "选中：",
	"spin_bearing": "方位 (°)",
	"spin_range": "距离 (m)",
	"spin_course": "航向 (°)",
	"spin_speed": "航速 (节)",
	"spin_own_course": "本艇航向 (°)",
	"spin_own_speed": "本艇航速 (节)",
	"spin_own_depth": "本艇深度 (m)",
	"page_sonar": "声呐",
	"page_tracks": "航迹",
	"page_weapons": "武器",
	"page_own": "本艇",
	"sec_sonar_operator": "声呐操作员",
	"sec_mark_groups": "Mark 组",
	"sec_fit_details": "拟合详情",
	"sec_status": "状态",
	"sec_automation": "自动化",
	"btn_mark": "标记",
	"btn_auto_fit": "自动拟合 TMA（选中目标）",
	"btn_accept_system": "√ 接受为系统解",
	"trial_params": "试拟参数（手动）",
	"no_fit_yet": "尚未拟合。",
	"cam_view": "镜头 / 视图",
	"btn_reset_view": "复位视图",
	"btn_auto_frame": "自动取景",
	"chk_all_lob": "全部方位线（LOB）历史",
	"chk_sel_only": "仅选中航迹",
	"btn_show_truth": "显示真值（开发）",
	"contacts_title": "接触列表（点击选择）",
	"layers": "图层",
	"bt_local": "BT 轴：相对（自动）",
	"bt_360": "BT 轴：0–360° 全览",
	"diagnostics": "诊断图：",
	"diag_closed": "关闭",
	"diag_bt": "方位—时间图（BT）",
	"diag_residual": "残差图",
	"diag_split": "分裂视图",
	# ---- 声呐操作员面板 ----
	"array": "基阵：",
	"btn_stream": "布放",
	"btn_hold": "保持",
	"btn_retract": "回收",
	"bb_relative": "相对方位（艇艏=0°）",
	"bb_true": "真北稳定（北=0°）",
	"bb_mode_relative": "相对（艇艏=0°）",
	"bb_mode_true": "真北稳定（北=0°）",
	"btn_reset_display": "复位显示",
	"fit_mode": "拟合模式",
	# ---- 主动声呐卡 ----
	"active_sonar": "主动声呐",
	"btn_ping": "发射脉冲",
	"latest_returns": "最近回波",
	"tma_link": "TMA 联动",
	"btn_take_control": "接管控制",
	"tip_take_control": "切换到手动：保留测距证据，停止自动重拟合试拟线",
	"apply_prompt": "将距离证据应用到试拟线？",
	"btn_apply": "应用",
	"btn_reject": "拒绝",
	"btn_undo_assoc": "撤销最近一次关联",
	# ---- 武器页 ----
	"btn_fire": "发射鱼雷",
	"fire_mode": "发射模式",
	"chk_shallow": "浅深攻击（12 米）",
	"program_prelaunch": "发射前参数（航向/深度/引信）",
	"wire_label": "线导",
	"in_water_title": "在水武器",
	"no_in_water": "水中无鱼雷",
	"tip_cut_wire": "切断导线（仅导线已连接时可用）",
	"auto_label": "自动",
	# ---- 反制 / 告警 / 自动化 ----
	"countermeasures": "反制措施",
	"brg_deg": "方位(°)",
	"btn_mobile": "发射声诱饵",
	"btn_jammer": "发射干扰器",
	"weapon_alerts": "武器告警",
	"tubes_placeholder": "鱼雷管：-",
	"no_alerts": "暂无告警",
	"lbl_auto": "自动",
	"btn_upper": "▲ 上升",
	"btn_lower": "▼ 下降",
	"own_maneuver": "本艇机动",
	"add_mark_to": "加入 Mark 组：",
	"btn_new_group": "＋ 新建组",
	"assoc_label": "关联方式：",
	"btn_apply_suggest": "应用建议关联",
	"btn_remove_last": "移除最近的 Mark",
	"btn_undo": "撤销",
	"auto_pick": "（自动）",
	# ---- 威胁 HUD / 右键菜单动作反馈 ----
	"torpedo_alert": "鱼雷警报",
	"btn_view_threat": "查看",
	"threat_detail_hint": "威胁详情见航迹页",
	"ruler_placeholder": "测距尺：本批未实现（占位）",
	"mark_group_set_to": "当前 Mark 组：",
	"presite_done": "已按方位预填概略射击 — 未发射",
	"presite_no_bearing": "预填失败：该接触无可测方位",
	"wire_cut_done": "导线已切断（转入自导）",
	"wire_cut_reject": "切断被拒：",
	"selection_cleared": "已清除选择",
	# ---- 事件日志行前缀 ----
	"evt_fire_mode": "发射模式",
	"evt_torpedo_away": "鱼雷出管",
	"evt_fire_reject": "发射被拒",
	"evt_submit": "系统解提交",
	"evt_low_quality": "质量偏低",
	"evt_submit_reject": "提交被拒",
	"evt_needs_evidence": "证据不足",
	"evt_no_selection": "缺少选中目标",
	# ---- 状态行（active ping / 拖曳阵 / 拟合，%s 等占位由调用方注入）----
	"st_ready": "就绪：点击接触后自动拟合 TMA",
	"st_tma_result": "TMA 解",
	"st_undo": "主动回波关联已撤销 — 需要重新拟合",
	"st_active_refit": "主动测距已融合（自动）— 正在重拟合试拟线…",
	"st_active_apply": "主动测距已到达 — 是否应用到试拟线？",
	"st_active_manual": "主动测距已到达（手动）— 试拟线未变，需要重新拟合",
	"st_array_to": "基阵切换 →",
	"st_autocrew_on": "自动船员：开",
	"st_autocrew_off": "自动船员：关",
	"st_autocrew_mark": "自动船员标记了一个新探测",
	"st_assoc_mode": "Mark 关联方式 →",
	"st_mark_group": "新 Mark 加入组：",
	"st_mark_group_auto": "新 Mark 加入组：（自动）",
	"st_towed_stream": "拖曳阵延伸中…",
	"st_towed_retract": "拖曳阵回收中…",
	"st_towed_hold": "拖曳阵保持长度：",
	"st_towed_cmd": "拖曳阵长度指令 →",
	"st_manual_mark": "手动 Mark：新接触",
	"st_no_contact": "未选中接触 — 先点击一个接触",
	"st_selected": "已选中",
	"st_selected_hint": "已选中 — 自动拟合将使用该接触",
	"st_echo_fused": "主动测距已在同一航迹融合 — 原选中保持不变",
	"st_ping_unavailable": "主动声呐不可用：本艇未安装主动基阵",
	"st_ping_recharge": "脉冲重新装定中 / 有脉冲在途",
	"st_ping_tx": "主动脉冲已发射 — 正在监听回波（我方正在暴露！）",
	"st_ping_no_return": "脉冲周期结束 — 未收到回波",
	"st_take_control": "已接管：切换为手动，证据保留，停止自动重拟合",
	# ---- 图例 / 画布标签 ----
	"legend_launch": "发射瞬态",
	"legend_noise": "鱼雷噪声",
	"legend_ping": "主动脉冲",
	"legend_return": "主动回波",
	"legend_best": "最优拟合",
	"legend_alt": "备选解 A/B/C",
	"legend_trial": "试拟解",
	"legend_system": "系统解",
	"legend_outlier": "野值",
	"legend_lob": "LOB 方位线",
	"legend_sigma": "σ 置信带",
	"legend_fit": "拟合航迹",
	"legend_truth": "真值航迹",
	"legend_threat": "威胁航迹",
	"band_surf": "海面",
	"band_up": "上层",
	"band_low": "下层",
	"band_bot": "海底",
	"residual_hint": "点击切换：度/米/σ",
	"truth_watermark": "开发真值 — 非玩家情报",
	"coast_tag": "外推",
	# ---- 终局 ----
	"mission_failed": "任务失败",
	"mission_time": "任务时间",
	"btn_restart_seed": "使用相同随机种子重试",
	"btn_main_menu": "返回主菜单",
	"reason_torpedo_hit": "鱼雷命中，本艇损失",
	# ---- 主动声呐卡参数行 / 其他控件 ----
	"param_mode": "模式",
	"param_frequency": "频率",
	"param_source_level": "源级",
	"param_listen_window": "监听窗",
	"param_exposure": "暴露度",
	"param_track": "航迹",
	"param_evidence": "证据",
	"param_fit": "拟合",
	"ret_tooltip": "脉冲 #%d @ %.0fs — 点击选择关联接触",
	"prog_search_half": "搜索半角(°)",
	"prog_pattern": "搜索模式",
	"prog_active": "主动开机条件",
	"prog_autonomy": "自治授权条件",
	"prog_val": "值",
	"prog_fuze": "引信",
	"prog_arm": "解保距离 m",
	"iw_btn_left": "←5°",
	"iw_btn_right": "→5°",
	"iw_btn_up": "▲上层",
	"iw_btn_low": "▼下层",
	"iw_btn_shallow": "▲浅深12m",
	"iw_btn_speed": "速度",
	"iw_btn_active_on": "主动开机",
	"iw_btn_active_off": "主机关闭",
	"iw_btn_autonomy": "授权自治",
	"iw_btn_wireonly": "回到仅线导",
	"iw_btn_accept": "接受航迹",
	"iw_btn_cut": "切断导线",
	"iw_trk": "航迹",
	"iw_guid_trk": "线导航迹",
	"iw_tgt_unknown": "未知",
	"iw_no_candidate": "无候选航迹",
	"iw_accept_tip": "接受最优候选（辅助）",
	"iw_wire_tip": "需要导线已连接（当前 %s）",
	"iw_tx_tip": "主动开机需要导线%s",
	"suggestion_fmt": "建议关联到 %s",
	"apply_prompt_2": "待应用：",
	"slots_fmt": "槽位 %d | %s",
	"bda_summary": "战果汇总",
	"status_fmt": "时间 %.0f 秒 | 测量 %d",
	"ping_unavail_tip": "本平台未装备主动声呐。",
	"ping_busy_tip": "单脉冲在途/充电中 — 等待回波结束",
	"ping_recharge_tip": "主动声呐充电中",
	"ping_cd_tip": "充电中 %.0f 秒",
	"ping_tip_ready": "主动声呐就绪 — 单脉冲",
	"ping_tip_transmitting": "脉冲已发射 — 正在监听回波",
	"ping_tip_listening": "监听中 — 定长回波窗开启",
	"ping_tip_return": "已收到回波 — 充电中",
	"ping_tip_noreturn": "未收到回波 — 充电中",
	"decoy_reject": "诱饵发射被拒：%s",
	"decoy_launch": "诱饵已投放 %s @%.0f°",
	"decoy_unknown": "未知",
	"nb_lofar_title": "窄带 / LOFAR（频率-时间）",
	"nb_band": "窄带频段",
	"demon_env_title": "DEMON 包络（叶片谐波）",
	"classification": "分类",
	"classification_dash": "分类：-",
	"towed": "拖曳阵：",
	"towed_stowed": "已回收",
	"towed_absent": "本舰未安装拖曳阵",
	"demon_dash": "DEMON 分析：-",
	"demon_fmt": "DEMON 分析：桨频 %.2f±%.2f Hz 叶片数 %s 航速 %.1f±%.1f 节",
	"tow_tip_full": "已到满缆长",
	"tow_tip_stowed": "已完全回收",
	"tow_tip_holding": "已在持缆长",
	"cmd_rejected_fmt": "命令被拒（%s）",
	"tx_fmt": "发射机 %s",
	"listen_no_return_evt": "监听结束无回波",
}

## mark_flow 自由状态句 → 中文（显示层替换对，S109 §10.2）。
const _MARK_CN := [
	["Mark exists — selected ", "Mark 已存在 — 已选中 "],
	[" (no new evidence)", "（无新证据）"],
	["Mark ignored: bearing inconsistent with ", "Mark 被忽略：方位与 "],
	[" (LOCKED)", "（锁定当前组）不一致"],
	["Suggestion dropped", "建议关联已丢弃"],
	["No pending suggestion", "没有待应用的建议关联"],
	["SUGGEST associate ", "建议关联 "],
	["SUGGEST apply ", "建议已应用："],
	["SUGGEST rebind ", "建议改绑："],
	["Marked ", "已 Mark "],
	[" deg -> ", "° → "],
	[" (LR pair)", "（左右舷对）"],
	["REASSIGN ", "改绑 "],
	["Reassigned ", "已改绑 "],
	[" measurement(s) ", " 条测量 "],
	["REMOVE last mark on ", "移除最近 Mark："],
	["Removed last mark on ", "已移除最近 Mark："],
	[" (undo available)", "（可撤销）"],
	["UNDO restore ", "撤销恢复 "],
	["Undo: restored last mark on ", "撤销：已恢复最近 Mark："],
	["NEW GROUP ", "新建 Mark 组 "],
	["New mark group ", "新 Mark 组 "],
	[" (active)", "（当前组）"],
	["Nothing to remove on ", "无可移除标记："],
	["Remove failed on ", "移除失败："],
	["Nothing to undo", "没有可撤销操作"],
	["No tracker", "无航迹管理器"],
]

## 缺键计数（zh_cn_ui_test AT-35 要求为 0：所有显示键都必须进目录）。
static var missing_keys: Dictionary = {}


## mark_flow 返回的自由状态句（内部英文）→ 中文显示（内部值不改）。
static func mark_status(st: String) -> String:
	if st == "":
		return ""
	for pair in _MARK_CN:
		st = st.replace(str(pair[0]), str(pair[1]))
	return st


static func t(key: String) -> String:
	var m: Variant = LABELS.get(key)
	if m == null:
		missing_keys[key] = int(missing_keys.get(key, 0)) + 1
		return key
	return str(m)


static func reset_missing() -> void:
	missing_keys = {}


# ---------------------------------------------------------------- 枚举映射
static func mode(k: String) -> String:
	return str(_MODE.get(k, k))


static func tx(k: String) -> String:
	return str(_TX.get(k, k))


static func auth(k: String) -> String:
	return str(_AUTH.get(k, k))


static func steer(k: String) -> String:
	return str(_STEER.get(k, k))


static func speed_mode(k: String) -> String:
	return str(_SPEEDMODE.get(k, k))


static func src(k: String) -> String:
	return str(_SRC.get(k, k))


static func miss(k: String) -> String:
	return str(_MISS.get(k, k))


static func depth_preset(k: String) -> String:
	return str(_DEPTHPRESET.get(k, k))


static func pattern(k: String) -> String:
	return str(_PATTERN.get(k, k))


static func enmode(k: String) -> String:
	return str(_ENMODE.get(k, k))


static func fuze_mode(k: String) -> String:
	return str(_FUEZEMODE.get(k, k))


static func fuze_state(k: String) -> String:
	return str(_FUEZESTATE.get(k, k))


static func arr(k: String) -> String:
	return str(_ARRAY.get(k, k))


static func ping_mode(k: String) -> String:
	return str(_PINGMODE.get(k, k))


static func exposure(k: String) -> String:
	for pre in _EXPO:
		if k.begins_with(pre):
			return str(_EXPO[pre])
	return k


static func decoy(k: String) -> String:
	return str(_DECOY.get(k, k))


static func roe(k: String) -> String:
	return str(_ROE.get(k, k))


static func assoc(k: String) -> String:
	return str(_ASSOC.get(k, k))


static func ping(k: String) -> String:
	return str(_PING.get(k, k))


static func threat(k: String) -> String:
	return str(_THREAT.get(k, k))


static func mission(k: String) -> String:
	return str(_MISSION.get(k, k))


static func klass(k: String) -> String:
	return str(_CLASS.get(k, k))


static func event(k: String) -> String:
	return str(_EVENT.get(k, k))


static func tp_state(k: String) -> String:
	return str(_TP_STATE.get(k, k))


static func seeker(k: String) -> String:
	return str(_SEEKER.get(k, k))


static func wire(k: String) -> String:
	return str(_WIRE.get(k, k))


static func fire_mode(k: String) -> String:
	return str(_FIRE_MODE.get(k, k))


static func group(k: String) -> String:
	return str(_GROUP.get(k, k))


static func rx(k: String) -> String:
	return str(_RX.get(k, k))


static func fit(k: String) -> String:
	return str(_FIT.get(k, k))


## 命令拒绝原因（内部英文码 → 玩家中文；含动态状态注入的模板）。
static func reject(r: String) -> String:
	if r == "":
		return ""
	var exact: Variant = _REJECT.get(r)
	if exact == null:
		exact = _SUBMIT.get(r)
	if exact == null:
		exact = _FIT.get(r) if _FIT.has(r) else null
	if exact != null:
		return str(exact)
	if r.begins_with("STALE "):
		return "已过期（%s）" % fit(r.substr(6))
	if r.begins_with("INVALID STATE "):
		return "任务状态非法：%s" % mission(r.substr(14))
	if r.begins_with("WIRE "):
		return "导线状态：%s" % wire(r.substr(5))
	return r
