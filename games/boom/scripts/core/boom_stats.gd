class_name BoomStats
extends RefCounted
## M8 属性系统（design_m8_attributes.md §3）：局内成长数值容器。
## 纯数据 + 纯函数，零 UI / 零节点依赖，可无头断言。
## 升级卡由 BoomLevelUpPanel 三选一产生，经 BoomGame.apply_level_upgrade 落到本类；
## 玩家机体数值由 BoomGame._apply_stats_to_player 落地。
## 防御力不进入普通等级成长（§3.2），只由法器/技能/特殊效果写入 defense 字段。

const KIND_DMG: String = "dmg"  # 伤害 +10%（固定增幅，乘最终攻击力）
const KIND_ASPD: String = "atk_speed"  # 攻击速度 +10%（固定增幅，缩短普攻间隔/挥斩周期）
const KIND_CRIT: String = "crit_rate"  # 暴击率 +3 个百分点（固定数额）
const KIND_CRIT_DMG: String = "crit_dmg"  # 暴击伤害 +15 个百分点（固定数额）
const KIND_HASTE: String = "haste"  # 存档键兼容；效果为技能冷却缩减 -8%
const KIND_SPEED: String = "speed"  # 移动速度 +8%（固定增幅）
const KIND_DODGE: String = "dodge"  # 闪避率 +3 个百分点（稀有选项，上限 20%）
const KIND_HEAL: String = "heal"  # 回满生命（一次性效果，不进堆叠；由 BoomGame 消费）

## 普通等级升级池（design §3.1；heal 一次性效果走特殊路径，dodge 为稀有卡）。
const KINDS: Array[String] = [
	KIND_DMG,
	KIND_ASPD,
	KIND_CRIT,
	KIND_CRIT_DMG,
	KIND_HASTE,
	KIND_SPEED,
	KIND_DODGE,
	KIND_HEAL,
]

# 每档固定获得量（design §3.1 数值表）。
const DMG_PCT_PER_STACK: float = 0.10
const ASPD_PCT_PER_STACK: float = 0.10
const CRIT_PCT_PER_STACK: float = 0.03
const CRIT_DMG_PCT_PER_STACK: float = 0.15
const HASTE_PCT_PER_STACK: float = 0.08
const COOLDOWN_REDUCTION_CAP: float = 0.40
const MOVE_MULT_PER_STACK: float = 1.08  # 移速 ×1.08（叠加乘算）
const DODGE_PCT_PER_STACK: float = 0.03
const DODGE_CAP: float = 0.20  # 闪避上限 20%（§8）

# 暴击与减伤基线（§6/§7）。
const BASE_CRIT_DMG: float = 1.50  # 基础暴击伤害 150%
const MITIGATION_CAP: float = 0.40  # 伤害减免 40% 封顶

var dmg_stacks: int = 0
var aspd_stacks: int = 0
var crit_stacks: int = 0
var crit_dmg_stacks: int = 0
var haste_stacks: int = 0
var speed_stacks: int = 0
var dodge_stacks: int = 0
## 防御力：整数评级；不随等级自动增加（§3.2/§7.1），只由特殊效果改变。
var defense: int = 0


func reset() -> void:
	dmg_stacks = 0
	aspd_stacks = 0
	crit_stacks = 0
	crit_dmg_stacks = 0
	haste_stacks = 0
	speed_stacks = 0
	dodge_stacks = 0
	defense = 0


## 应用一档升级；KIND_HEAL 是一次性效果，本类不堆叠但视为成功（消费方处理回复）。
## 未知 kind 返回 false（防御）。
func apply(kind: String) -> bool:
	match kind:
		KIND_DMG:
			dmg_stacks += 1
		KIND_ASPD:
			aspd_stacks += 1
		KIND_CRIT:
			crit_stacks += 1
		KIND_CRIT_DMG:
			crit_dmg_stacks += 1
		KIND_HASTE:
			haste_stacks += 1
		KIND_SPEED:
			speed_stacks += 1
		KIND_DODGE:
			dodge_stacks += 1
		KIND_HEAL:
			pass  # 一次性效果：不加堆叠，回复由 BoomGame 执行
		_:
			return false
	return true


func stacks(kind: String) -> int:
	var map: Dictionary = {
		KIND_DMG: dmg_stacks,
		KIND_ASPD: aspd_stacks,
		KIND_CRIT: crit_stacks,
		KIND_CRIT_DMG: crit_dmg_stacks,
		KIND_HASTE: haste_stacks,
		KIND_SPEED: speed_stacks,
		KIND_DODGE: dodge_stacks,
	}
	return int(map.get(kind, 0))


## 伤害加成倍率：最终攻击力 = floor(基础攻击力 × dmg_mult())（§5.2）。
func dmg_mult() -> float:
	return 1.0 + DMG_PCT_PER_STACK * float(dmg_stacks)


## 攻速倍率：普攻间隔 / 挥斩周期 ÷ aspd_mult()。
func aspd_mult() -> float:
	return 1.0 + ASPD_PCT_PER_STACK * float(aspd_stacks)


## 暴击率（0 → 3% → 6% …，上限 100%）。
func crit_rate() -> float:
	return minf(1.0, CRIT_PCT_PER_STACK * float(crit_stacks))


## 暴击倍率：150% → 165% → 180% …（§6.2）。
func crit_dmg_mult() -> float:
	return BASE_CRIT_DMG + CRIT_DMG_PCT_PER_STACK * float(crit_dmg_stacks)


## 兼容旧存档/测试的急速倍率；新结算统一使用直接冷却缩减。
func haste_mult() -> float:
	return 1.0 + HASTE_PCT_PER_STACK * float(haste_stacks)


## 冷却缩减：每档固定 -8%，最多 -40%；最终冷却 = 基础冷却 × (1-CDR)。
func cooldown_reduction() -> float:
	return minf(COOLDOWN_REDUCTION_CAP, HASTE_PCT_PER_STACK * float(haste_stacks))


## 移速倍率（BoomPlayer.MOVE_SPEED * weapon.move_mult 之上，乘算）。
func move_mult() -> float:
	return pow(MOVE_MULT_PER_STACK, float(speed_stacks))


## 闪避率（0 → 3% → 6% …，20% 封顶，§8）。
func dodge_rate() -> float:
	return minf(DODGE_CAP, DODGE_PCT_PER_STACK * float(dodge_stacks))


## 减伤公式（§7.2）：min(40%, 防御力 / (防御力 + 100))。
static func mitigation_for(p_defense: int) -> float:
	if p_defense <= 0:
		return 0.0
	return minf(MITIGATION_CAP, float(p_defense) / float(p_defense + 100))


func mitigation() -> float:
	return mitigation_for(defense)


## 本局已消耗的升级总档数（HUD/结算展示用；heal 一次性不计数）。
func total_stacks() -> int:
	return (
		dmg_stacks
		+ aspd_stacks
		+ crit_stacks
		+ crit_dmg_stacks
		+ haste_stacks
		+ speed_stacks
		+ dodge_stacks
	)
