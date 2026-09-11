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
	"PLAYER_VICTORY": "任务胜利",
	"MISSION_ENDED": "任务已结束",
	"TORPEDO_HIT": "鱼雷命中，本艇损失",
	"TARGET_DESTROYED": "目标被击沉，任务达成",
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
	"MERCHANT": "商船",
	"WARNOTHINGSHIP": "水面舰艇",
	"SUBSONAR": "潜艇",
}

## S1-11 Batch 7 / AT-42：瀑布调色板 / 自动增益 / 拖曳阵状态的中文标签。
const _PALETTE := {"HOT": "高对比", "GRAYSCALE": "灰度", "BLUE": "蓝调", "AMBER": "琥珀"}
const _AGC := {"AGC SLOW": "自动增益·慢", "AGC FAST": "自动增益·快", "AGC OFF": "自动增益·关"}
const _TOWED := {
	"STOWED": "已收起",
	"STREAMING": "布放中",
	"HOLD_PARTIAL": "保持长度",
	"RETRIEVING": "回收中",
	"UNKNOWN": "未知",
}

## AC-03：拖曳阵性能状态中文名（BEST/DEGRADED/UNSTABLE/STOWED）。
const _TOWED_PERF := {
	"BEST": "最佳",
	"DEGRADED": "可用（性能下降）",
	"UNSTABLE": "不稳定",
	"STOWED": "无有效孔径",
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
	# S1-11 Batch 7：鱼雷任务态/导线/主动机事件（武器页事件流逐条中文）。
	"LAUNCH": "鱼雷发射",
	"TRANSIT": "航渡",
	"ACQUIRING": "捕获中",
	"LOCKED": "已锁定",
	"COAST": "短时丢失",
	"LOST_REACQUIRE": "重新搜索",
	"REACQUIRE": "重新截获",
	"BAND_SEARCH_SWITCH": "换带搜索",
	"ACTIVE_TRIGGER_SET": "主动开机点已设",
	"ACTIVE_TX_ON": "主动声呐开启",
	"ACTIVE_TX_OFF": "主动声呐关闭",
	"AUTONOMY_AUTHORIZED": "已授权自动",
	"RETURN_WIRE_ONLY": "回到线导",
	"WIRE_CUT": "导线已切断",
	"ROUTE_UPDATE": "航线已更新",
	"ROUTE_CLEARED": "航线已清除",
	"CONTACT_REJECTED_SAFETY": "己方接触已拒收",
	"FUZE_SAFETY_INHIBIT": "引信本侧安全抑制",
}

## 鱼雷 mission_state（Torpedo.mission_state_name()）
const _TP_STATE := {
	"STOWED": "在库",
	"LAUNCHING": "发射中",
	"TRANSIT": "线导航行",
	"ACQUIRING": "捕获中",
	"LOCKED_ATTACK": "已锁定",
	"COAST": "短时丢失",
	"LOST_REACQUIRE": "重搜",
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
	"TRANSITION": "过渡带",
	"CUSTOM": "定制深度",
}

## S1-11 §5.5：地图浮动栏深度策略（玩家唯一简化覆盖）。
const _DEPTHPOLICY := {"AUTO": "自动", "UPPER": "上层", "LOWER": "下层"}

## S1-11 §4.3：地图开机点/主动声呐开关状态。
const _ONOFF := {"on": "开", "off": "关"}

## S1-11 §7.1/§7.4：深度概率主导层 → 层带预设键；未知文案。
const _DEPTH_UNKNOWN := "深度未知"
const _DOM_TO_PRESET := {
	"SURFACE_LIKELY": "SURFACE",
	"UPPER_LIKELY": "UPPER",
	"LOWER_LIKELY": "LOWER",
}

## S1-11 §7.5：深度证据来源（含鱼雷导线回传）。
const _DEPTHSRC := {
	"TORPEDO_WIRE": "鱼雷回传",
	"SEEKER": "导引头",
	"OWN_PITCH": "本艇俯仰测角",
	"MULTIPATH": "多路径时差",
	"LAYER_COMPARE": "变深层间比较",
	"UNKNOWN": "未知来源",
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

## DC-04：诱饵状态（与 Decoy.state() 单一口径一致）。
const _DECOY_STATE := {"STANDBY": "待激活", "ACTIVE": "工作中", "EXPIRED": "已过期"}

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
	"page_tactics": "战术",
	"page_weapons": "武器",
	"page_own": "本艇",
	"sec_sonar_operator": "声呐操作员",
	"sec_mark_groups": "Mark 组",
	"sec_fit_details": "拟合详情",
	"sec_contact_card": "接触卡",
	"sec_tactics_contacts": "接触",
	"contact_action_view": "查看",
	"contact_action_track": "优先跟踪",
	"contact_action_confirm": "主动确认",
	"contact_action_target": "设为攻击目标",
	"contact_details": "详情",
	"contact_no_selection": "未选中接触",
	"threat_extra_fmt": "另有 %d 枚，方位 %s",
	"threat_none": "无来袭威胁",
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
	# S1-11 D-01：玩家唯一发射方式 = 地图航线。
	"btn_route_draw": "绘制航线",
	"btn_route_undo": "撤销航点",
	"btn_route_clear": "清除航线",
	"route_none": "航线：未绘制（点「绘制航线」后在海图上点选航路点）",
	"route_drawing_fmt": "航线：绘制中 %d/%d 个航路点（右键打开航线菜单，Enter 完成 / Esc 取消）",
	"route_ready_fmt": "航线：%d 个航路点，可发射",
	"route_need_points": "航线无效：至少需要 1 个未来航路点（双击或 Enter 无效，请继续点选）",
	"chk_shallow": "浅深攻击（12 米）",
	"program_prelaunch": "发射前参数（航向/深度/引信）",
	"wire_label": "线导",
	"in_water_title": "在水武器",
	"no_in_water": "水中无鱼雷",
	"tip_cut_wire": "切断导线（仅导线已连接时可用）",
	"auto_label": "自动",
	# ---- S1-11 Batch 5：地图浮动栏 / 在线重画 / 地图命令 ----
	"bar_reroute": "重画航线",
	"bar_center": "居中",
	"bar_depth": "深度：",
	"bar_active_on": "主动声呐：开",
	"bar_active_off": "主动声呐：关",
	"bar_reroute_tip": "重画剩余航线需要导线已连接（当前 %s）",
	"wire_cmd_disabled": "导线未连接，无法下达命令（%s）",
	"reroute_reject": "重画航线被拒：",
	"reroute_locked": "已锁定，捕获后不允许覆盖航线",
	"reroute_hint": "重画航线中：在地图上点选新航路点，右键「完成航线」提交 — ",
	"reroute_done": "航线已更新 — ",
	"reroute_cancelled": "已取消重画航线",
	"reroute_invalid": "航线无效（需起点 + 至少 1 个航路点）",
	"map_cmd_reject": "地图命令被拒：",
	"map_goto_done": "已令 %s 向该点航行",
	"map_waypoint_done": "已为 %s 追加航路点",
	"map_active_at_done": "%s 将在航程 %s 开启主动声呐",
	"map_route_cleared": "已清除 %s 的剩余航线",
	"map_active_done": "%s 主动声呐：%s",
	"map_depth_done": "%s 深度策略：%s",
	"route_full": "航路点已满（最多 4 个）",
	"route_in_water": "在水：%s（地图航线）",
	"on": "开",
	"off": "关",
	# ---- S1-11 Batch 5/6：在水摘要与状态遥测 ----
	"last_weapon_fmt": "上一武器 %s：%s",
	"miss_reason": "脱靶原因",
	"min_pass_fmt": "最近通过 %.0fm",
	"summary_select": "选择 %s",
	"summary_select_tip": "在地图上选中并居中该鱼雷",
	"sat_suffix": "（饱和）",
	"guidance_pn": "期望：比例导航拦截",
	"guidance_course_fmt": "期望航向 %.0f°",
	"depth_cmd_fmt": "→ 深度 %.0fm（来源 %s ETA %s）",
	"depth_actual_fmt": "实际深度 %.0fm",
	"depth_policy_row": "深度策略 %s",
	"fuze_row": "引信 %s",
	"depth_est_row": "敌方深度估计 %s",
	"depth_band_unknown": "深度未知",
	# ---- S1-11 Batch 5：武器页摘要 ----
	"tubes_summary": "鱼雷管与在水摘要（点击行选中）",
	"tubes_fmt": "鱼雷管：%d/%d 已装填　在水：%d",
	"summary_line_fmt": "%s：%s / 主动%s / 导线%s / 燃料 %.0fs / %s",
	"seeker_phase": "导引头",
	"evt_detonation_fmt": "%s 起爆（最近通过 %.0fm）",
	"evt_track_accepted_fmt": "%s 已接受航迹 #%s（辅助）",
	"evt_active_ping_fmt": "%s 主动脉冲 %s 已发射",
	"evt_echo_fmt": "%s 收到回波",
	"evt_listen_no_return_fmt": "%s 监听结束 — 无回波",
	"evt_fuze_armed_fmt": "%s 引信已解保（已航行 %.0fm）",
	"evt_route_update_fmt": "%s 已接收新航线",
	"evt_route_cleared_fmt": "%s 剩余航线已清除",
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
	# ---- MK-01：当前查看 / 手动落点写入（两个独立信息，避免看写混淆）----
	"none_value": "无",
	"mark_view_fmt": "当前查看：%s",
	"mark_write_fmt": "手动落点写入：%s",
	"mark_write_lock_fmt": "手动落点写入：%s（锁定）",
	"mark_write_auto": "手动落点写入：（自动关联）",
	"mark_pending_fmt": "有落点待处理（%.0f°）— 目的组不可用：",
	"btn_move_to_group": "移入当前组",
	"btn_attach_pending": "归入当前组",
	"btn_new_group_from_pending": "为待处理点新建组",
	# ---- 威胁 HUD / 右键菜单动作反馈 ----
	"torpedo_alert": "鱼雷警报",
	"btn_view_threat": "查看",
	"threat_detail_hint": "威胁详情见航迹页",
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
	"evt_route_needed": "请先在地图上绘制航线再发射",
	"evt_route_cleared": "航线已清除",
	"evt_route_committed": "航线已就绪，可发射",
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
	# MK-02：Shift 临时目的组必须明示；MK-03：重复点提示可显式改绑。
	"st_mark_temp": "本次落点临时追加到：",
	"st_mark_dup_movable": "该点已归属 %s — 未新增证据；可用「移入当前组」改绑",
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
	# ---- PG-03 无有效回波的可解释说明（只列本艇/设备已知因素，不泄露目标 Truth）----
	"no_return_window": "本次未获得有效回波：监听窗时延上限 %.1f 千米（超出即不可接收）",
	"nr_window": "监听窗时延上限",
	"nr_own_noise": "本艇航速高、自噪声升高",
	"nr_ambient": "海况差、环境噪声高",
	# ---- PG-03 到达即显示的临时位置点 / PG-04 位置估计档位 ----
	"pending_assoc": "待关联",
	"est_last_known": "最近估计位置",
	"est_predicted": "预测位置",
	"est_pos_fmt": "%s · 距离 %.2f 千米（σ%.0f 米）· 位置 1σ %.0f 米",
	"pos_only_hint": "单次主动观测仅给出位置（航速航向未知）",
	# ---- 图例 / 画布标签 ----
	"legend_launch": "发射瞬态",
	"legend_noise": "鱼雷噪声",
	"legend_ping": "主动脉冲",
	"legend_return": "主动回波",
	"legend_contact": "接触（未选中）",
	"legend_contact_sel": "接触（选中/展开）",
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
	# ---- S1-11 Batch 7 / AT-42：本艇机动 + 拖曳阵列文案（去裸英文）----
	"btn_turn_left": "左转 5°",
	"btn_turn_right": "右转 5°",
	"btn_speed_up": "+2 节",
	"btn_speed_down": "-2 节",
	"own_act_fmt": "实际 航向 %.0f° 航速 %.1f 节",
	"own_cmd_course_fmt": " → 命令 %.0f°（约 %.0f 秒）",
	"own_cmd_speed_fmt": " → 命令 %.1f 节（约 %.0f 秒）",
	"own_depth_fmt": " | 深度 %.0f 米",
	"own_depth_cmd_fmt": " → %.0f 米（约 %.0f 秒）",
	# ---- P1-B UI-02/UI-03：图形操纵（罗盘外圈 / 深度条）文案 ----
	# 图形与数字双向同步：命令完成后保留"最后设定"显示，避免回落到内部 -1 哨兵。
	"own_course_actual_fmt": "实际 %.0f°",
	"own_course_cmd_fmt": "命令 %.0f°",
	"own_course_cmd_eta_fmt": "命令 %.0f° ±%.0f 秒",
	"own_course_preview_fmt": "预览 %.0f°",
	"own_graphic_hint": "外圈拖动转向 · 松开提交 · 右键/Esc 取消",
	"own_last_cmd_fmt": " | 最后设定 航向 %.0f° 深度 %.0f 米",
	"depth_tag_actual": "实际",
	"depth_tag_cmd": "命令",
	"depth_tag_preview": "预览",
	"depth_preview_fmt": "预览 %.0f 米（松开提交）",
	"depth_preview_idle_fmt": "拖动深度条设定深度（当前 %.0f 米）",
	"towed_none": "拖曳阵：未布放",
	"towed_line_fmt": "拖曳阵：%s | 实长 %.0f 米 / 命令 %.0f 米 | 阵位 %.0f° | 可用 %d%%",
	# AC-03：阵列名称旁持续标注线阵的两项固有特性（高灵敏 + 左右歧义）。
	"towed_flags": "拖曳阵：高灵敏度／左右歧义",
	# AC-03：性能状态 + 四项独立损失（dB 估计），让退化原因可解释。
	"towed_perf_fmt": "性能 %s | 损失 孔径%.1f 沉降%.1f 弯曲%.1f 流噪%.1f dB",
	"towed_perf_reason_bend": "刚过死区/严重弯曲",
	"towed_perf_reason_speed": "超出正常拖速",
	"residual_hint": "点击切换：度/米/σ",
	"truth_watermark": "开发真值 — 非玩家情报",
	"coast_tag": "外推",
	# ---- 终局 ----
	"mission_failed": "任务失败",
	"mission_victory": "任务胜利",
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
	"cm_ready_fmt": "弹药 %d",
	"cm_spare_fmt": "备用 %d",
	"cm_reload_fmt": "装填中 %.0fs",
	"decoy_src_measured": "实测",
	"decoy_src_estimated": "程序估计",
	"decoy_offer_mobile": "向此方向投放机动诱饵",
	"decoy_offer_jammer": "向此方向投放干扰器",
	"decoy_offer_fmt": "（真方位 %03d°，待发 %d/备用 %d）",
	"decoy_offer_mission_ended": "任务已结束",
	"decoy_offer_unsupported": "该类型未装备",
	"decoy_offer_no_rounds": "无待发弹",
	"decoy_offer_dir_unclear": "方向不明确（离本艇过近）",
	"decoy_offer_cooldown_fmt": "冷却中 %.0f 秒",
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
	# ---- MK-03/MK-05/MK-06 新增裁决路径（应用顺序敏感：长句在前）----
	["Mark already exists (owner ", "Mark 已存在（归属 "],
	[") - no new evidence; use Move-to-current-group to rebind ", "）— 未新增证据；可用「移入当前组」改绑 "],
	["Mark already exists", "Mark 已存在"],
	[" - no new evidence", " — 未新增证据"],
	["Group ", "目的组 "],
	[" rejected the mark - kept pending", " 拒绝了该落点 — 已保留待处理"],
	[" rejected the pending mark", " 拒绝了待处理落点"],
	[" unavailable - mark kept pending (new group / pick another)", " 不可用 — 落点已保留待处理（请新建组或改选）"],
	[" unavailable", " 不可用"],
	[" (temp Shift destination)", "（Shift 临时目的组）"],
	[" - Apply to rebind to ", " — 应用后改绑到 "],
	["Suggestion rejected", "建议已拒绝（未改动任何组）"],
	["No target group", "未指定目的组"],
	["Nothing to move", "没有可移动的证据"],
	["Evidence not owned by any group", "该证据不属于任何组"],
	["Move failed (group kept intact)", "改绑失败（证据组保持完整）"],
	["Moved ", "已移动 "],
	["No pending mark", "没有待处理落点"],
	["Pending mark attached to ", "待处理落点已归入 "],
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


static func depth_policy(k: String) -> String:
	return str(_DEPTHPOLICY.get(k, k))


static func onoff(k: String) -> String:
	return str(_ONOFF.get(k, k))


## S1-11 §7.4：深度概率摘要 → 中文（<0.55 未知；0.55–0.75 可能；>0.75 大概率）。
## 只有存在真实垂向测量（带置信区间的米数）时才显示区间，绝不把二维测距
## 伪装成精确水深。
static func depth_band_summary(summary: Dictionary) -> String:
	if summary.is_empty():
		return str(_DEPTH_UNKNOWN)
	var interval: Array = summary.get("depth_interval_m", [])
	if interval.size() >= 2 and float(summary.get("interval_confidence", 0.0)) > 0.0:
		return (
			"可能 %.0f–%.0fm（%d%%）"
			% [
				float(interval[0]),
				float(interval[1]),
				int(round(float(summary.get("interval_confidence", 0.0)) * 100.0))
			]
		)
	var conf: float = float(summary.get("confidence", 0.0))
	if conf < 0.55:
		return str(_DEPTH_UNKNOWN)
	var dom: String = str(summary.get("dominant", "UNKNOWN"))
	var layer: String = str(_DEPTHPRESET.get(_DOM_TO_PRESET.get(dom, ""), dom))
	var pct: int = int(round(float(summary.get("probability", 0.0)) * 100.0))
	var prefix: String = "大概率" if conf > 0.75 else "可能"
	if dom == "SURFACE_LIKELY":
		return "%s近水面 %d%%" % [prefix, pct]
	if dom == "UPPER_LIKELY":
		return "%s%s %d%%" % [prefix, layer, pct]
	if dom == "LOWER_LIKELY":
		return "%s%s %d%%" % [prefix, layer, pct]
	return str(_DEPTH_UNKNOWN)


## 深度估计来源 → 中文（§7.5 必须标明"鱼雷回传"）。
static func depth_source(k: String) -> String:
	return str(_DEPTHSRC.get(k, k))


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


static func decoy_state(k: String) -> String:
	return str(_DECOY_STATE.get(k, k))


## DC-05：诱饵投放原因代码 → 中文（含冷却剩余秒数）。空代码 → 空串（可用）。
static func decoy_offer_reason(code: String, cooldown_s: float = 0.0) -> String:
	match code:
		"":
			return ""
		"MISSION_ENDED":
			return str(t("decoy_offer_mission_ended"))
		"DECOY_TYPE_UNSUPPORTED":
			return str(t("decoy_offer_unsupported"))
		"DECOY_NO_ROUNDS":
			return str(t("decoy_offer_no_rounds"))
		"DECOY_DIR_UNCLEAR":
			return str(t("decoy_offer_dir_unclear"))
		"DECOY_COOLDOWN":
			return t("decoy_offer_cooldown_fmt") % maxf(cooldown_s, 0.0)
	return reject(code)


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


## AT-42：瀑布调色板 / 自动增益 / 拖曳阵状态的中文显示名（内部键保持英文）。
static func palette(k: String) -> String:
	return str(_PALETTE.get(k, k))


static func agc(k: String) -> String:
	return str(_AGC.get(k, k))


static func towed_state(k: String) -> String:
	return str(_TOWED.get(k, k))


static func towed_perf(k: String) -> String:
	return str(_TOWED_PERF.get(k, k))


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
