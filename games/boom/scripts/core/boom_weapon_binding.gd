extends RefCounted
## 所有坐标为最终 256px 帧内像素，原点左上，Y 向下；不是源图坐标。
## 身体锚点与法器握柄独立标注，允许不同比例的武器共用身体动画。
##
## 三层分离（§可扩展绑定配置）：
##   战斗武器 ID（BoomWeapons 的 id，如 bubble/greatsword）
##     → 视觉配置 ID（CONFIGS 的 key，决定武器素材/比例/握柄/策略）
##       → 动画形态 form（决定身体动作集与攻击语义）。
## 新增武器 = 注册一个 CONFIGS 条目（含素材、逐帧握柄、缺失动作策略），
## 不修改玩家代码；战斗 ID 通过 combat_ids 显式映射到视觉配置。

## 比例规则（§比例及层级）：身体 pixel_size（世界单位/像素），工具与运行时共用。
const BODY_PIXEL: float = 0.0076

## 身体持械手逐帧锚点（掌心）。同一动作全程同一只手（同手连续性）。
const HANDS: Dictionary = {
	"idle_down": [Vector2(92, 149), Vector2(90, 138), Vector2(88, 150), Vector2(92, 147)],
	"idle_up": [Vector2(157, 109)],
	"idle_left": [Vector2(89, 131)],
	"idle_right": [Vector2(177, 120)],
	"idle_down_right": [Vector2(134, 135)],
	"idle_down_left": [Vector2(91, 140)],
	"idle_up_left": [Vector2(123, 120)],
	"idle_up_right": [Vector2(167, 115)],
	"move_down":
	[
		Vector2(103, 133),
		Vector2(140, 135),
		Vector2(142, 130),
		Vector2(116, 141),
		Vector2(132, 147),
		Vector2(149, 106)
	],
	"move_up":
	[
		Vector2(110, 122),
		Vector2(112, 118),
		Vector2(112, 120),
		Vector2(114, 118),
		Vector2(113, 110),
		Vector2(112, 116)
	],
	"move_left":
	[
		Vector2(89, 131),
		Vector2(96, 123),
		Vector2(103, 124),
		Vector2(107, 122),
		Vector2(101, 128),
		Vector2(105, 124)
	],
	"move_right":
	[
		Vector2(177, 120),
		Vector2(184, 105),
		Vector2(185, 112),
		Vector2(187, 125),
		Vector2(187, 104),
		Vector2(178, 118)
	],
	"move_down_right":
	[
		Vector2(140, 127),
		Vector2(162, 120),
		Vector2(164, 121),
		Vector2(152, 133),
		Vector2(160, 126),
		Vector2(164, 112)
	],
	"move_down_left":
	[
		Vector2(96, 132),
		Vector2(118, 129),
		Vector2(123, 127),
		Vector2(112, 132),
		Vector2(117, 138),
		Vector2(131, 115)
	],
	"move_up_left":
	[
		Vector2(100, 127),
		Vector2(104, 121),
		Vector2(108, 122),
		Vector2(111, 120),
		Vector2(107, 119),
		Vector2(109, 120)
	],
	"move_up_right":
	[
		Vector2(144, 121),
		Vector2(148, 112),
		Vector2(149, 116),
		Vector2(151, 122),
		Vector2(150, 107),
		Vector2(145, 117)
	],
	"recoil": [Vector2(75, 139), Vector2(64, 77), Vector2(112, 137)],
	"swing":
	[Vector2(90, 43), Vector2(81, 65), Vector2(80, 77), Vector2(100, 86), Vector2(81, 139)],
}
## 握柄逐帧锚点，按视觉配置 ID 索引（CONFIGS.grips 指向这里的 key）。
const GRIPS: Dictionary = {
	"night_ruler":
	{
		"idle": [Vector2(138, 157), Vector2(138, 157), Vector2(138, 157), Vector2(138, 157)],
		"move":
		[
			Vector2(138, 157),
			Vector2(138, 157),
			Vector2(138, 157),
			Vector2(138, 157),
			Vector2(138, 157),
			Vector2(138, 157)
		],
		"recoil": [Vector2(118, 140), Vector2(149, 153), Vector2(137, 145)],
	},
	## 测试配置专用子集：只声明 idle/recoil，验证 missing_action_policy=stow。
	"test_pennant":
	{
		"idle": [Vector2(138, 157), Vector2(138, 157), Vector2(138, 157), Vector2(138, 157)],
		"recoil": [Vector2(118, 140), Vector2(149, 153), Vector2(137, 145)],
	},
	"ink_brush":
	{
		"idle": [Vector2(153, 91), Vector2(157, 91), Vector2(158, 91), Vector2(158, 91)],
		"move":
		[
			Vector2(161, 102),
			Vector2(161, 102),
			Vector2(161, 102),
			Vector2(161, 102),
			Vector2(161, 102),
			Vector2(161, 102)
		],
		"swing":
		[
			Vector2(115, 100),
			Vector2(112, 101),
			Vector2(136, 96),
			Vector2(135, 94),
			Vector2(102, 104)
		],
	},
}
## 身体在这些动作中收起手持物；无对应握持动作时不让法器悬空。
const STOWED: Array[String] = ["hurt", "skill_cast", "knockdown"]

## 手部前景遮挡矩形（身体画布像素，Rect2(x, y, w, h)）。
## 机制：从同一帧身体贴图裁出该区域，以高于武器的优先级原位重绘——
## 与底层身体逐像素重合、零接缝，等效手指包住握柄。
## 约束：矩形只覆盖“应挡住武器”的手/衣袖区域；未标注的动作不出前景层
## （武器整体在身体之前，不会更错）。逐动作补全后可覆盖更多动作。
const HAND_RECTS: Dictionary = {
	"idle_down":
	[
		Rect2(74, 134, 40, 28),
		Rect2(72, 126, 40, 28),
		Rect2(70, 138, 40, 28),
		Rect2(74, 132, 40, 30),
	],
	"recoil":
	[
		Rect2(64, 128, 40, 28),
		Rect2(44, 56, 44, 32),
		Rect2(98, 126, 40, 28),
	],
	## swing 五帧（R1 返工后新帧 f4 已复验）：框住持械手/袖口，
	## 让加粗后的判笔杆被手指包握（前景层原位重绘）。
	"swing":
	[
		Rect2(70, 30, 40, 28),
		Rect2(61, 52, 40, 28),
		Rect2(60, 64, 40, 28),
		Rect2(80, 73, 40, 28),
		Rect2(61, 125, 40, 28),
	],
}

## 视觉绑定配置注册表。strips: 动作 → [文件名, 帧数]；grips 指向 GRIPS 的 key；
## missing_action_policy: stow=缺失动作收起武器（不报错），error=报错并隐藏。
const CONFIGS: Dictionary = {
	"night_ruler":
	{
		"combat_ids": ["bubble"],
		"form": "bubble",
		"weapon_dir": "res://assets/images/weapons/night_patrol/",
		"weapon_pixel": 0.0058,
		"strips":
		{
			"idle": ["night_ruler_idle", 4],
			"move": ["night_ruler_move", 6],
			"recoil": ["night_ruler_recoil", 3],
		},
		"grips": "night_ruler",
		"missing_action_policy": "stow",
	},
	"ink_brush":
	{
		"combat_ids": ["greatsword"],
		"form": "sword",
		"weapon_dir": "res://assets/images/weapons/night_patrol/",
		"weapon_pixel": 0.0070,
		"effect_strip": ["res://assets/images/effects/ink_brush_swing_fx.png", 5],
		"effect_pixel": 0.0084,
		"strips":
		{
			"idle": ["ink_brush_idle", 4],
			"move": ["ink_brush_move", 6],
			"swing": ["ink_brush_swing", 5],
		},
		"grips": "ink_brush",
		"missing_action_policy": "stow",
	},
	## 测试配置（仅验证扩展能力，非正式游戏内容）：复用镇尺素材，
	## 独立比例 0.0066 与独立注册；故意缺 move 条验证 stow 策略。
	"test_pennant":
	{
		"combat_ids": ["test_pennant"],
		"form": "bubble",
		"weapon_dir": "res://assets/images/weapons/night_patrol/",
		"weapon_pixel": 0.0066,
		"strips":
		{
			"idle": ["night_ruler_idle", 4],
			"recoil": ["night_ruler_recoil", 3],
		},
		"grips": "test_pennant",
		"missing_action_policy": "stow",
	},
}


static func visual_for_combat(combat_id: String) -> String:
	for vid in CONFIGS:
		if combat_id in CONFIGS[vid]["combat_ids"]:
			return vid
	push_error("No visual config for combat id: %s" % combat_id)
	return ""


static func config(visual_id: String) -> Dictionary:
	return CONFIGS.get(visual_id, {})


static func resolve(
	visual_id: String, action: String, frame: int, body_pixel: float, weapon_pixel: float
) -> Dictionary:
	if action in STOWED:
		return {"visible": false}
	var weapon_action := action
	if action.begins_with("idle_"):
		weapon_action = "idle"
	elif action.begins_with("move_"):
		weapon_action = "move"
	var cfg := config(visual_id)
	if cfg.is_empty() or not HANDS.has(action):
		push_error("Missing weapon binding: %s/%s" % [visual_id, action])
		return {"visible": false}
	var grips_table: Dictionary = GRIPS.get(cfg["grips"], {})
	if not grips_table.has(weapon_action):
		# 缺失动作策略：stow 显式收起（不静默截断帧号、不报错刷屏）。
		if cfg["missing_action_policy"] == "error":
			push_error("Missing grip action: %s/%s" % [visual_id, weapon_action])
		return {"visible": false}
	var hands: Array = HANDS[action]
	var grips: Array = grips_table[weapon_action]
	if frame < 0 or frame >= hands.size() or frame >= grips.size():
		push_error("Missing weapon binding frame: %s/%s/%d" % [visual_id, action, frame])
		return {"visible": false}
	var hand: Vector2 = hands[frame]
	var grip: Vector2 = grips[frame]
	var mirrored := action.ends_with("_left")
	if mirrored:
		grip.x = 256.0 - grip.x
	var shift: Vector2 = (
		(hand - Vector2(128, 128)) * body_pixel / weapon_pixel - (grip - Vector2(128, 128))
	)
	return {
		"visible": true,
		"action": weapon_action,
		"frame": frame,
		# SpriteBase3D.offset 与世界轴同向（探针 probe_offset_y.gd 实证 y+ 向上），
		# 单位为武器画布像素；直接等于掌心-握柄换算差，禁止再取反 y。
		"offset": shift,
		"flip_h": mirrored,
		"priority": 1 if action.begins_with("idle_up") or action.begins_with("move_up") else 3,
	}
