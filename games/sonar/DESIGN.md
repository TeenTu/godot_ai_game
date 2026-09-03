# 潜艇声呐 / TMA 模拟游戏 — 设计与实现蓝图

> 目标引擎：Godot 4.5 (GDScript) / Web 导出，复用现有多游戏 CI/CD 流水线。
> 核心原则：**Truth（后台真实状态）与 Measurement（传感器观测）严格分离**。
> 正常游戏界面绝不读取 / 显示 Truth，Truth 仅通过调试模式 "Show Truth" 呈现。

---

## 0. 信息链总览（本项目灵魂）

```
真实目标 Truth
  → 声学辐射（AcousticProfile × 平台运动 → SL）
  → 水下传播（EnvironmentModel → TL, N_eff）
  → 阵列测量（SensorArray → SE → P_d → 带噪 bearing/range）
  → 接触标记（Measurement 聚合成 Track）
  → 目标分类（窄带谱线 / 特征 → classification_probabilities）
  → TMA 运动解算（对 Track 做几何/最小二乘 → 玩家 Trial Solution）
  → 火控解（玩家 "Enter Solution" → System Solution）
  → 武器搜索与攻击（读 System Solution，不读 Truth）
```

五层数据状态（必须始终在代码里严格区分，不允许混用）：

| 层 | 名称 | 谁写的 | 玩家能看到吗 |
|----|------|--------|-------------|
| Truth | 后台真实状态 | 仿真引擎 | 否（仅调试 Show Truth） |
| Measurement | 传感器观测 | SensorArray | 是（声呐/海图原始读数） |
| Track | 接触航迹 | 接触管理器 | 是 |
| TrialSolution | 玩家试算解 | 玩家调整 | 是（可编辑） |
| SystemSolution | 已提交火控解 | 点 Enter 后复制 | 是（火控/武器只读它） |

---

## 1. 单位与坐标约定（全局唯一，禁止改）

- 内部距离：**米**；地图坐标：二维笛卡尔，**x 向东，y 向北**。
- 深度：**米，向下为正**。
- 内部时间：**秒**；航速显示：**节**（1 kn = 0.514444 m/s）。
- 航向 / 方位：**正北为 0°，顺时针增加**，一律归一化到 `[0,360)`。
- 方位残差：归一化到 `[-180,180)`。

平台运动（每固定步长）：

```
x += Vm * sin(psi_deg_to_rad) * dt
y += Vm * cos(psi_deg_to_rad) * dt     # 注意从北顺时针
```

本艇到目标的真实方位（海军方位，从北顺时针，**不要**错用数学坐标系）：

```
theta_true = wrap360( atan2(x_t - x_o, y_t - y_o) )
```

> 这是最容易写错的地方。`atan2` 输出是"从 +x 逆时针"，要换算成"从 +y(北) 顺时针"。
> 封装一个 `nav_utils.gd` 集中处理，全项目只用它。

---

## 2. 目录 / 模块结构（分阶段，每阶段独立可测）

```
games/sonar/
  project.godot
  export_presets.cfg
  assets/
    fonts/           # 中文字体子集（复用 suika 的裁剪流程）
  scripts/
    # ---- 阶段一：仿真内核（纯逻辑，无 UI，可无头测试）----
    nav_utils.gd        # 角度/坐标/节换算的纯函数库
    truth_entity.gd     # Truth 平台状态 + 运动学更新
    acoustic_profile.gd # 平台声学特征（SL_0、空化曲线、谱线）
    environment_model.gd# 水声环境（海况、跃变层、TL 系数）
    propagation.gd      # TL 计算 + 多源噪声合成(N_eff) + 被动/主动 SE
    sensor_array.gd     # 传感器：探测概率、方位误差、Lofar 数据生成
    measurement.gd      # 一次观测记录
    measurement_generator.gd # 把 Truth→Measurement 的唯一通道
    scenario_loader.gd  # 从 JSON/YAML 加载场景（平台、环境、参数）
    world.gd            # 固定步长仿真主循环（持 Truth 实体 + 生成器）
    config_loader.gd    # JSON 参数加载（一切可配置，不写死在代码里）

    # ---- 阶段二：接触管理 + TMA ----
    track.gd            # 接触航迹（测量历史、分类概率、运动假设）
    tracker.gd          # 测量→航迹关联（最邻近/航迹置信）
    classifier.gd       # 基于谱线/特征的分类
    tma_solver.gd       # TMA 解算（对接触做运动参数估计）

    # ---- 阶段三：UI / 游戏层 ----
    game_state.gd       # 暂停/1x/2x/4x/8x 时间加速
    trial_solution.gd   # 玩家试算解（可编辑）
    system_solution.gd  # 已提交火控解
    sonar_display.gd    # 声呐瀑布/方位显示
    nav_map.gd          # 海图 + 接触 + 本艇航迹
    hud.gd              # 深度/航速/控制面板
    debug_overlay.gd    # "Show Truth" 调试层
    main.gd             # 装配 + 驱动

  scenes/
    main.tscn
  tools/
    play_test.gd        # CI 冒烟测试（断言确定性 PASS）
    stage1_test.gd      # 阶段一纯逻辑单元测试（可无头运行）
    scenario_*.json     # 各阶段测试场景
```

阶段划分（**完成一阶段并通过测试，才做下一阶段**）：

- **阶段一（本次交付）**：nav_utils + 运动学 + 声学/传播/传感器 + 测量生成器 + world 固定步长循环。全部无 UI，纯逻辑，配 `stage1_test.gd` 做确定性断言。产出：能从一个场景 JSON 生成一系列 Measurement 流，且复现种子完全相同。
- **阶段二**：接触跟踪（Track 关联）+ TMA 解算。产出：由测量流得到接触航迹与运动参数估计，无头测试验证精度。
- **阶段三**：UI 化（声呐显示、海图、Trial/System Solution、时间加速、Show Truth）+ 武器火控。产出：可玩版本。

---

## 3. 数据结构（阶段一先落地这些）

### 3.1 TruthEntity
```
id, class_id, side
position_east_m, position_north_m, depth_m
course_deg, speed_kn, turn_rate_deg_s, acceleration
commanded_course_deg, commanded_speed_kn   # S1-02/G-05：命令值/实际值分离（<0=无命令）
platform_type, damage_state
```
运动学更新按 §1 公式，支持匀速 / 转向 / 变速。

**S1-02 / G-05 命令值与实际值分离**：UI/决策层只能通过 `command_course(deg)` /
`command_speed(kn)` 下令，实际航向/航速按最大转向率/加速度限制渐变逼近
（`clamp(wrap180(cmd−act), ±turn_rate·dt)` / `clamp(dv, ±accel·dt)`；场景未配速率时
兜底 1.5°/s、0.25kn/s）。到达命令值（<0.05° / <0.01kn）自动清命令。
一旦下达过命令，旧常率转向/常加速路径退役（命令与旧 AI 机动互斥；未下命令的
AI 目标/旧测试仍可直接写 actual）。

### 3.2 AcousticProfile
```
broadband_base_level_db        # SL0
speed_noise_curve              # SL0 + A*log10(1+(V/Vref)^n)
cavitation_depth_speed_curve   # Vcav(z)：随深度增加而提高
tonal_lines                     # [{freq_hz, level_db}] 窄带谱线
turns_per_knot, blade_count, shaft_count
active_target_strength          # TS（主动声呐用）
decoy_similarity
```

### 3.3 EnvironmentModel
```
environment_type, sea_state
ambient_noise_by_frequency     # {freq: level_db}
layer_depth_m, layer_strength_db
bottom_type, bottom_loss_db
sound_speed_profile
convergence_zone_interval, convergence_zone_width
```
TL 基础：`TL = K*log10(max(r,1)) + alpha(f)*r_km + L_environment`

### 3.4 SensorArray
```
sensor_id, array_type, owner_id, frequency_range
array_gain_db(AG), detection_threshold_db(DT)
bearing_error_model            # sigma_min/max, SE0, k_sigma
coverage_sector, baffle_sector
update_interval_s, tracker_capacity, deployed
# TOWED 物理见下方 S1-03 状态机（towed_array.gd）：STOWED/STREAMING/HOLD_PARTIAL/
# RETRIEVING + actual/commanded_tow_length_m + array_heading_deg（滞后阵轴）
```

> **TOWED 可控长度拖曳阵（S1-03，`scripts/towed_array.gd`）**：操作员层的 TOWED
> 不再把 `array_heading` 恒等于本艇航向，而是独立状态机 + 可控缆长：
> 状态 `STOWED ↔ STREAMING ↔ HOLD_PARTIAL ↔ RETRIEVING`，实际缆长 ACT 与命令
> 缆长 CMD 分离，`set_length_command/stream/hold/retrieve` 在任意长度可停可反向，
> 缆长按固定收放速率（stream/retrieve_rate_m_s）逼近命令（不是百分比动画）。
> 部分长度真实参与声学：有效孔径 `q_L=clamp((L−L_dead)/(L_full−L_dead),0,1)`，
> `AG_eff = AG_full + 10log10(q_L) + L_bend + L_speed`（孔径/弯曲/高速三项独立），
> 回收第一帧起性能连续下降，绝不"开始回收即静音"；`L≤L_dead` 或 STOWED 时
> `is_acoustically_active()=false`，严格无 TOWED 测量。阵轴对本艇转向做一阶滞后
> 收敛，tau 随 q_L 在 short/full_length_heading_tau_s 间插值，并按本艇实际航速标定
> （`speed_scale=clamp(ref/spd,0.5,2.5)`，慢速更飘、快速拖直）。阵列声学中心
> `p_array = p_own − 0.5(L_dead+L)·[sin ψa, cos ψa]` 作为 TOWED 观察站位。
> 状态机挂在 own(`TruthEntity.towed`)，`advance` 每步注入实际航速推进，纯逻辑可无头测。
> 未配置 `own_ship.tow` 时本艇无拖曳阵：TOWED 选项禁用、可用度=0、无任何
> TOWED 测量（无"跟艇+满可用"的虚构回退）。
>
> **TOWED 左右舷镜像歧义（S1-03A/S1-06）**：单线阵对阵轴两侧等角响应，OperatorSonar
> 为每次到达生成共享 pair_id/SE/噪声的 A/B 候选峰（`θ_A=ψa+β`、`θ_B=ψa−β`，
> 消歧前对玩家等价）；`create_mark_group` 产出一组两个 Measurement 进同一 Track。
> TmaSolver.solve_auto 按 branch 过滤（A=branch≥0，B=branch≤0，非歧义两边保留）
> 分别拟合，softmax 分支权重 `w_A=1/(1+exp(−(J_B−J_A)/2))`；可观测性合格
> （rank≥4 且 legs≥2）且最佳权重≥门限（默认 0.9）才 `mirror_resolved=true`，
> 否则 `AMBIGUOUS_LR`（落选分支保留在 alternatives）。

### 3.5 Measurement
```
measurement_id, timestamp, sensor_id
observer_position_at_measurement   # ← 关键：LOB 从"测量时本艇位置"发出
measured_bearing_deg, bearing_sigma_deg
measured_range_m(可选), range_sigma_m(可选)
signal_excess_db(SE), snr_db
detected_frequencies, classification_features
ambiguous_pair_id(可选)        # TOWED 镜像对共享 ID（S1-03A）
ambiguity_branch(可选)         # +1=A 支 / -1=B 支（S1-03A）
ambiguity_resolved             # TMA 消歧结果（S1-06）
array_heading_at_measurement_deg  # 测量时刻阵轴（镜像 θ_B=2ψa−θ_A 依据）
array_center_east_m/north_m    # 测量时刻阵心（观察站位，S1-03）
actual_tow_length_m            # 测量时刻实际缆长
```

### 3.6 Track / TrialSolution / SystemSolution
见阶段二/三定义（§2），本次阶段一只预留接口。

---

## 4. 统一声呐模型（阶段一实现）

> **G-03 / S1-04 单一实现点**：全部公式收敛在 `scripts/acoustic_service.gd`
> （AcousticService，全静态）。SensorArray 的公共 API 与 OperatorSonar 一律委托它，
> 严禁散落 `20log10*1.2` 之类简化公式。传播损失/有效噪声委托 EnvironmentModel
> （TL 含扩展+吸收+环境项；N_eff 多源线性合成）。

### 4.1 被动声呐信号余量
```
SE_passive = SL - TL - N_eff + AG - DT
```
多噪声源**不得直接加 dB**，先转线性再合成：
```
N_eff = 10*log10( Σ 10^(Ni/10) )
```

### 4.2 主动声呐
```
SE_active = SL_ping - 2*TL + TS - N_eff + AG - DT   # 两段路径损失
```

**S1-04 主动 Ping 指令模型**：主动探测是**玩家主动指令**（不是每 tick 自动
传感器）。`World.issue_ping()` 发射脉冲——**回波按往返传播延迟到达，声呐不是
光速**：
```
τ = 2R/c          # 一去一回传播时间；c = 声速 ≈ 1500m/s
R = c·τ/2         # 测距即测时（AcousticService.echo_travel_time_s / range_from_echo_time_s）
```
**单在途状态机（REQ-16/17）**：`READY →(issue_ping) LISTENING →(回波全部
结算/监听窗口结束) RETURN | NO_RETURN →(冷却到) READY`。会话未清时新 Ping
一律被拒，绝不清理未返回回波。**硬件显式配置（REQ-20）**：场景必须有
`own_ship.active_sonar` 块（或 sensors 含 `array_type=="active"` 阵）才可
Ping；无硬件 → 状态 `UNAVAILABLE`、按钮禁用，绝不自动构造缺省主动阵。
艇首主动阵参数（ping_sl_db / cooldown_s / freq_min_hz / freq_max_hz /
array_gain_db / sound_speed_m_s / listen_window_s）全部由
`own_ship.active_sonar` 覆盖；场景配了 `array_type=="active"` 传感器则复用之。

发射瞬间只按当前几何登记各目标的在途回波（`arrive_t = now + 2R/c` 与
`range_ref_m`，**测距同源基准 REQ-19**）；结算在到达时刻
（`sim_time >= arrive_t`）触发：跑主动 SE 检测、以 `range_ref_m` 为基准加
噪声得 `measured_range_m`（τ 内目标位移并入 `range_sigma_m`），绝不读到达
时刻 Truth 距离回填。detected 回波 append 进 measurements 并由
`ActivePingController` 喂 Tracker（等价一次玩家触发的 "P" Mark），随后经
`on_echo_hits` 回调自动选中该接触并 REFIT——**主动 range 进入 TMA 解算**
（range 残差行 + `RANGE AIDED` 摘要，S1-04B-REQ-08/REQ-10），而不是只显示
在面板上当数字被丢弃。冷却从发射时刻起算；**面板状态完全来自
`ping_state_name()`**（UNAVAILABLE/READY/LISTENING/RETURN/NO_RETURN），
不显示 "echo in ~Xs" 之类由 Truth 推导的回波倒计时（ISSUE-06）。
主动工作频率须权衡吸收（`alpha(f_khz)r_km` 随频率涨）——远距主动探测要低频。
**隐蔽性代价**：发 ping 即暴露（面板橙字提示 + 世界记录 `_last_ping_t` 供
敌方被动截获逻辑读取；AI 联动归武器批次）。

### 4.3 概率探测（不硬门限）
```
P_d = 1 / (1 + exp(-SE / k_d))
```
SE 高 → P_d 高 / 瀑布亮 / 方位稳 / 谱线全 / 分类快；
接近门限 → 间歇接触、谱线中断、短暂误报、忽隐忽现。
OperatorSonar 对每个候选峰按 P_d 掷骰（S1-04）：无 SE>0 硬切，弱目标间歇出现。

### 4.3.1 背景噪声 texture（S1-04.4 / G-04）
瀑布每 bin 背景为时间相关随机噪声，替代固定纯色底：
```
state_{t+1} = ρ·state_t + (1−ρ)·randn     # AR(1)，ρ=0.75，幅度≈2.5dB
```
相邻行均匀相关（肉眼可辨纹理），行间均差 <2dB；宽带/窄带/DEMON 各自独立状态。

### 4.4 方位误差（随 SE 变化）
```
theta_hat = wrap360( theta_true + N(0, sigma_theta^2) )
sigma_theta(SE) = sigma_min + (sigma_max - sigma_min) / (1 + exp((SE-SE0)/k_sigma))
```
弱接触抖动大，强接触稳定。**强信号 ≠ 近距离**。

### 4.5 声源级 / 空化
```
SL_BB(V,z) = SL0 + A*log10(1+(V/Vref)^n) + C_cav * I(V > Vcav(z))
```
本艇航速↑ → 自曝↑ + 自噪↑ → 探测能力↓。这段构成"隐蔽性管理"玩法的数学内核。

---

## 5. 随机性 / 可复现性

- 所有随机测量统一走一个**可注入种子的 RNG**（Godot `RandomNumberGenerator`，显式 `seed()`）。
- 场景 JSON 里存 `seed`，同种子必须产出完全相同测量流。
- 阶段一测试即用固定种子断言特定时刻的 SE / bearing / P_d 落在期望区间，避免 flaky。

---

## 6. 阶段一验收标准（本交付）

- [x] 工程 `games/sonar/` 能被 CI 识别（project.godot + Web 导出预设）。
- [x] 纯逻辑模块全部完成，无任何 UI 依赖。
- [x] `tools/stage1_test.gd` 无头运行，固定种子断言通过。
- [x] `tools/play_test.gd` 冒烟测试 `PLAY_TEST result=PASS`（供 CI）。
- [ ] 场景 JSON 驱动，参数全部外部化。
- [ ] 随机测量可复现（同 seed 同结果）。

> 阶段一的"可玩性"不强（还没有界面），它是一台能稳定产出带噪声测量流、
> 且模型行为符合声呐物理规律的"仿真内核"。这是后面所有玩法的基础。
