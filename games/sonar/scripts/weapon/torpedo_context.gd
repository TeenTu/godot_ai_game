class_name TorpedoContext
extends RefCounted
## torpedo_context.gd — 鱼雷 step() 的注入上下文（S1-07 §12.1）。
##
## 代替旧的 step(dt, sim_time, targets:Array)：鱼雷 Guidance 子模块只获得
## SeekerTrack / 自身状态 / 服务接口，绝不直接接收 TruthEntity targets。
## 结构上保证"航行/搜索段绝不读 Truth"从注释声明变成类型约束。
##
## 本批（Commit 1/2）只填 env / depth_model；emission_bus、sensor_adapter、
## collision/fuze 引擎在 Commit 5/6 起逐个接入，字段先预留不实现。

var env: RefCounted = null  # EnvironmentModel（TL/N_eff 统一实现）
var depth_model: RefCounted = null  # DepthLayerModel（Commit 2，可为 null=旧二维场景）
var emission_bus: RefCounted = null  # 预留：AcousticEmissionBus（Commit 5）
var sensor_adapter: RefCounted = null  # 预留：TorpedoSensorAdapter（Commit 6）
