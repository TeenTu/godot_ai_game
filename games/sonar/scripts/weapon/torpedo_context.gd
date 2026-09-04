class_name TorpedoContext
extends RefCounted
## torpedo_context.gd — 鱼雷 step() 的注入上下文（S1-07 §12.1）。
##
## 代替旧的 step(dt, sim_time, targets:Array)：鱼雷 Guidance 子模块只获得
## SeekerTrack / 自身状态 / 服务接口，绝不直接接收 TruthEntity targets。
## 结构上保证"航行/搜索段绝不读 Truth"从注释声明变成类型约束。
##
## 本批（Commit 1/2）只填 env / depth_model；Commit 5 起接 emission_bus，
## Commit 6 起接 sensor_adapter（TorpedoSensorAdapter，输出净化 SeekerReturn）；
## collision/fuze 引擎后续 Commit 接入，字段先预留不实现。

var env: RefCounted = null  # EnvironmentModel（TL/N_eff 统一实现）
var depth_model: RefCounted = null  # DepthLayerModel（Commit 2，可为 null=旧二维场景）
# Commit 5：AcousticEmissionBus（发射瞬态/航行噪声/主动 Ping 声源广播，§9.2）。
var emission_bus: RefCounted = null
# Commit 6：TorpedoSensorAdapter（仿真内核唯一可触 Truth 的武器侧对象，§6.5；
# 鱼雷经它周期采样/收主动回波，得到净化 SeekerReturn，绝不直接读 Truth）。
var sensor_adapter: TorpedoSensorAdapter = null
