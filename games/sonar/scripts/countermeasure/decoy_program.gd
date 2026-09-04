class_name DecoyProgram
extends RefCounted

## DecoyProgram（S1-07 §8.3，Commit 8）：单枚诱饵的发射程序。发射瞬间生成
## 不可变快照（snapshot()），实际部署的诱饵只读快照字段。

const TYPE_MOBILE := "MOBILE_DECOY"
const TYPE_JAMMER := "JAMMER_CONFUSER"

var launcher_id: String = "CM-1"
var decoy_type: String = TYPE_MOBILE
var launch_bearing_deg: float = 0.0
var initial_depth_band: String = WeaponProgram.DEPTH_BAND_UPPER
var commanded_depth_band: String = WeaponProgram.DEPTH_BAND_UPPER
var course_deg: float = 0.0  # 出舱后航向（MOBILE）
var speed_kn: float = 8.0  # MOBILE 巡航速度；JAMMER 恒低速/近似静止
var activation_delay_s: float = 2.0  # 出舱到声学激活的延时
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
	p.activation_delay_s = activation_delay_s
	p.lifetime_s = lifetime_s
	p.signature = signature
	p.signature_profile_id = signature_profile_id
	return p


## 合法性（§8.5 发射条件的数据面）。
func validate() -> Array:
	var errs: Array = []
	if decoy_type != TYPE_MOBILE and decoy_type != TYPE_JAMMER:
		errs.append("decoy_type unknown")
	if launch_bearing_deg < 0.0 or launch_bearing_deg >= 360.0:
		errs.append("launch_bearing out of range")
	if speed_kn < 0.0 or speed_kn > 30.0:
		errs.append("speed_kn out of range")
	if activation_delay_s < 0.0:
		errs.append("activation_delay negative")
	if lifetime_s <= 0.0:
		errs.append("lifetime must be positive")
	return errs
