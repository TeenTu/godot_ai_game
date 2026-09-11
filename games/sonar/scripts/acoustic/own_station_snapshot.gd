class_name OwnStationSnapshot
extends RefCounted
## own_station_snapshot.gd — PG-04：主动 Ping 的"观测参考站位"冻结快照。
##
## 动机：旧链路用**发射时刻**的几何距离（range_ref）配**到达时刻**的本艇站位与
## 方位——两个基准混用，远距/大机动时产生虚假精度。本类在发射瞬间冻结本艇站位
## （位置/深度/航速/航向/时刻）与该次观测的本艇导航位置不确定度，作为本次 Ping
## **全部**回波观测的唯一参考站位与参考时刻。
##
## 参考站位的残差（回波往返 τ 内本艇位移）不隐藏：结算方按
## motion_bias_m = 0.5·v·τ 记入 Measurement，由位置协方差显式吸收
## （见 ActivePositionObs.position_covariance）。
##
## 字段名与 TruthEntity 一致（position_east_m / position_north_m / depth_m /
## speed_kn / course_deg），可直接作为 MeasurementGenerator.generate_active 的
## observer 形参使用——不需要第二套几何约定。

## 冻结站位（米，绝对平面坐标）。
var position_east_m: float = 0.0
var position_north_m: float = 0.0
var depth_m: float = 0.0
var speed_kn: float = 0.0
var course_deg: float = 0.0
## 参考时刻（秒，= 发射时刻）。
var time_s: float = 0.0
## 本艇导航位置 1σ（m）：位置观测协方差 P_observer 项的来源。
var pos_sigma_m: float = 40.0


## 发射瞬间冻结本艇站位。pos_sigma_m < 0 → 用缺省导航不确定度。
static func capture(own: RefCounted, now_s: float, pos_sigma_m: float = -1.0) -> OwnStationSnapshot:
	var s := OwnStationSnapshot.new()
	s.position_east_m = float(own.position_east_m)
	s.position_north_m = float(own.position_north_m)
	s.depth_m = float(own.depth_m)
	s.speed_kn = float(own.speed_kn)
	s.course_deg = float(own.course_deg)
	s.time_s = now_s
	if pos_sigma_m > 0.0:
		s.pos_sigma_m = pos_sigma_m
	return s


## PG-04：运动近似偏差（m，1σ 计法）。本艇在往返 τ 内的位移无法从单次回波观测
## 得知，按半程位移记入协方差：0.5 · v · (t_arrive − t_ref)。
func motion_bias_m(arrive_time_s: float) -> float:
	var v_ms: float = NavUtils.kn_to_ms(speed_kn)
	return 0.5 * v_ms * maxf(arrive_time_s - time_s, 0.0)


func to_dict() -> Dictionary:
	return {
		"position_east_m": position_east_m,
		"position_north_m": position_north_m,
		"depth_m": depth_m,
		"speed_kn": speed_kn,
		"course_deg": course_deg,
		"time_s": time_s,
		"pos_sigma_m": pos_sigma_m,
	}
