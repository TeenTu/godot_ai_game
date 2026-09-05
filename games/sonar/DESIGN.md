# 潜艇声呐 / TMA 模拟游戏 — 设计与实现蓝图

> 目标引擎：Godot 4.5 (GDScript) / Web 导出，复用现有多游戏 CI/CD 流水线。
> 核心原则：**Truth（后台真实状态）与 Measurement（传感器观测）严格分离**。
> 正常游戏界面绝不读取 / 显示 Truth，Truth 仅通过调试模式 "Show Truth" 呈现。
>
> **S1-00 信息链热修状态（2026-09）：已完成 ①②③** —— ① detected/evidence_id
> 证据契约（miss 永不进玩家链，A/B 共享证据计数）；② 删主动自动旁路 +
> TMA robust refit 统一口径 + 残差行 schema（废除 residual_deg）；③ CI 主门禁
> （tools/ci_tests.txt 清单 + 非零退出码）。验收见 `tools/s100_integrity_test.gd`
> （D1-D8）与 OPERATIONS.md §5。

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

## 0.6 S1-07 武器 Seeker 重做（Commit 0-11 + S1-07A UI 已合入，2026-09）

需求文档：腾讯文档 DZk1OR1JqV0d1RWhN《S1-07 武器 Seeker 重做需求（AI Coding 版）》。
首批任务包（§17）= **Commit 0～2**；本批追加 **S1-07A UI（本艇深度控制）+
Commit 3（任意条件发射）+ Commit 4（WireLink 与 fallback）+ Commit 5（声学
画像 + EmissionBus）+ Commit 6（TorpedoSensorAdapter + SeekerReturn）**，
均已合入 sonar-dev：

- **Commit 0**：旧武器缺陷行为刻画测试（Truth 直读 / 单一 ENABLE_RANGE /
  target_id 进 UI / DEAD 自动补装）——重构后已删除，由新契约测试接管。
- **Commit 1（正交状态 + WeaponProgram）**：鱼雷拆成七个正交状态机——
  MissionState / SeekerState / ActiveTxState / GuidanceAuthority / WireState /
  DepthState / FuzeState，禁止一个 ENABLE 同时代表开机/主动/自主/解保。
  `WeaponProgram` 发射瞬间不可变快照（SOLUTION 预填；BEARING_ONLY/MANUAL
  入口已留，Commit 3 启用）。发射默认 **PASSIVE_LISTEN / ACTIVE_TX=OFF**
  （REQ-DECISION-01/02）。鱼雷 step 只收 `TorpedoContext`（无 Truth targets，
  类型级隔离）；发射管 LOADED→FIRING→EMPTY，**不自动补装**（reload_tube
  显式）。Seeker 目标选择属 Commit 6，本批鱼雷为"线导直航 + 被动监听"中间态。
- **Commit 2（S1-07A 双层伪三维）**：`DepthLayerModel`（UPPER/LOWER/
  TRANSITION + smoothstep w_cross + TL_layer=TL_base+w·L(f)）；本艇/敌艇/
  鱼雷统一连续升降（command/actual 分离、Vz 限速、禁瞬移）；跨层只降 Pd 不
  硬置零。旧二维场景无 `depth_layers` → disabled → 额外损失恒 0（零回归）。
- **S1-07A UI（本艇深度控制，§4.2 明示项补缺）**：右侧 Own Ship Maneuver 区
  抽成 `ui/own_maneuver_panel.gd`（Own Course/Speed/**Depth (m)** + ▲Upper/
  ▼Lower 层按钮 + ACT→CMD/换层 ETA/层带状态行）。层按钮只写
  `commanded_depth_m`（hold 70/180m 来自场景 depth_model，未启用回退默认）；
  实际深度按 Vz 限速逼近、无瞬移。`stage1_basic_passive.json` 启用
  `depth_layers`（旧场景缺省 disabled 兼容不变）；D7 场景集成测试（loader
  挂 depth_model / 本艇下潜 130m 按 2m/s / 跨层附加 TL>0 非零且不硬断）。
- **Commit 3（任意条件发射，§5.2）**：SystemSolution 变成可选预填——
  `WeaponProgram.make_manual/make_bearing_only` 工厂 + `WeaponSystem.
  fire_manual/fire_bearing_only`（无解、无距离概念，不触发射程联锁）；
  SOLUTION 保留 fire(sys) 射程联锁。UI：Fire 只要有装填管即可点，main_ui
  按上下文自动选 SOLUTION（有解）/ BEARING_ONLY（选中接触 LOB）/
  MANUAL（沿本艇艏向），weapon_panel 显示模式与风险提示；weapon_test w6
  翻转（无解 MANUAL 可发射）；`weapon_program_test` WPN-PROG-01..04。
- **Commit 4（WireLink 与 fallback，§5.4/§5.5）**：新增 `scripts/weapon/
  wire_link.gd`（放线/超长确定性断线/cut/命令门，无 Truth）；Torpedo 导线
  状态唯一源改为 `wire_link`（CONNECTED/BROKEN/CUT），线控命令门只认
  CONNECTED，断/切后拒绝新命令并执行 fallback——保持最后命令航向（按
  max_turn_rate 渐进转向）→ 预设 search depth band（内部命令不经过线控门）
  → 进入 SEARCH → 按 fallback 预设距离/时间自动授权自主与开启 active TX
  （`_advance_fallback_autonomy` + active OFF 也能按程序化条件自触发）。
  命令全部记 `command_log`（§5.1 CommandLog），绝不改写发射程序快照。
  `wire_guidance_test` WPN-WIRE-01..04（连接命令生效/速率逼近/断切拒绝/
  fallback 执行）。
- **Commit 5（TorpedoAcousticProfile + EmissionBus，§6.1/§6.2/§9.1/§9.2）**：
  新增 `scripts/weapon/torpedo_acoustic_profile.gd`——速度模式同时映射对地
  速度/续航/运行噪声源级（QUIET 28kn/1800s/112dB < CRUISE 40kn/1200s/128dB
  < HIGH 50kn/800s/146dB，§6.2：切模式绝不单改地图速度）+ 主动收发参数 +
  出管/动力启动瞬态（游戏性标定，全部可配置）；Torpedo 删常量改读 profile，
  `command_speed_mode` 按新旧模式续航比等比折算剩余燃料。新增 `scripts/
  acoustic/acoustic_emission_{event,bus}.gd`——统一声学事件 schema（字典，
  emitter 只带内部引用、绝不携带 target_id/Truth）与总线（MAX_EVENTS 1024、
  事件计数确定性）；`World.active_emissions`（S1-04C 契约）改为总线 events
  同一数组引用（R22 读方零改动），本艇主动 Ping 与鱼雷出管瞬态 / 动力启动 /
  运行噪声（按模式源级周期广播）/ 主动 Ping（按 profile 节拍）全部经
  `emission_bus.record` 落事件，截获 SE/Pd 与玩家声呐同源（连续概率非硬门限）。
  `torpedo_acoustic_test` WPN-ACOU-01..03（模式单调性 + 燃料折算 / 瞬态事件
  + 截获概率单调 / 主动 Ping 可截获 + 噪声随 HIGH 更响）。
- **Commit 6（TorpedoSensorAdapter + SeekerReturn，§6.3/§6.4/§6.5/§6.7）**：
  新增 `scripts/weapon/seeker_return.gd`（净化输出：return_id/timestamp/
  available_time/sensor_mode/detected/带噪方位/可选测距/SE/Pd/频谱特征/
  depth_relation/分类假设占位；to_dict 与字段绝不带 target_id、真实位置、
  damage_state，debug_truth_ref 玩法链恒空）与 `scripts/weapon/
  torpedo_sensor_adapter.gd`（仿真内核唯一可触 Truth 的武器侧对象：注入
  env/depth_model/RNG + Truth 声源数组）。被动采样与玩家声呐同源（SE_passive
  = SL_contact − TL_layer − N_eff(torpedo speed) + AG − DT，Pd 连续无硬门限，
  miss 帧无 return）；FOV=profile 水平波束；高速自噪抬 N_eff → 被动 SE 下降
  （§6.2）；跨温跃层 depth_relation=SAME/CROSS/TRANSITION 且 SE 降不硬断；
  主动 Ping 按 tau=2R/c 登记回波、到点结算（R_meas=c·tau/2+noise，测距同源
  REQ-19 纪律，绝不同 tick 瞬时返回）；误报独立生成器（false_alarm_rate）不
  绑定 target。Torpedo 接 ctx.sensor_adapter：出管后 passive_receiver_on 默认
  ON、按 1s 周期采样并收主动回波，SeekerReturn 净化为 seeker_returns（只记不
  转——捕获/转向属 Commit 7）；World.load_scenario 装配 adapter（contacts=
  targets）。`torpedo_seeker_test` WPN-SEEK-01/02/04/05 + miss/cross/speed/FA
  （被动默认 ON 收到 return / 被动无 range 且净化 / miss 确定性无 return /
  跨层 SE 降 / HIGH 自噪降被动 SE / 主动 TOF 延迟与测距 / 误报独立）。
- **Commit 7（§7，SeekerTrack + Guidance）**：新增 `seeker_track.gd`（§7.1
  航迹：平滑方位/方位率估计、可选主动测距、简化协方差、consecutive hits/
  misses、lock_quality 按 §7.3 示例模型 q+=α·meas_q−γ·innovation / miss
  −β，参数全配置化；score=w_q·q+w_se·SE+w_k·运动一致−w_i·创新+continuity
  bonus，§7.4）+ `torpedo_seeker.gd`（§7.2 关联：未钳位预测方位差过绝对
  门限+主动测距+深度层关系，绝不用 target_id；§7.3 滞回 SEARCH→ACQUIRING
  →TRACKING→LOST→REACQUIRE→SEARCH；§7.6 重搜扇区围绕最后预测方位扩大）
  + `torpedo_guidance.gd`（§7.7 纯函数制导：lead=方位率×提前时间追踪，只有
  被动方位绝不补 Truth range；§7.5 SNAKE/CIRCLE 搜索扫掠）。Torpedo 接入：
  净化 return 同步喂航迹机；期望航向优先级 制导>线控命令>搜索扫掠，全部
  限 max_turn_rate（绝无瞬时指向，WPN-SEEK-13）；TRACKING→ATTACK、LOST→
  SEARCH、主动测距近程→TERMINAL；WIRE_ONLY 恒不接管（听到也不擅自转向）；
  ASSISTED 经 ACCEPT_SEEKER_TRACK 接受候选。`torpedo_track_test` WPN-SEEK-
  06..13（单次不锁/连续捕获/miss 丢失/重搜不跟 Truth/重捕获/score 竞争与
  翻转/净化 API/限转向率）+ WIRE_ONLY 不转 + SEARCH 扇区扫掠。
- **Commit 8（§8，诱饵与干扰 + §6.1 谱线细节）**：新增
  `scripts/countermeasure/`（decoy_program/decoy/countermeasure_system）。
  Decoy 继承 TruthEntity 同一 AcousticContact 接口进 TorpedoSensorAdapter
  同一条声学采样链——Seeker 绝不读 is_decoy/类型（CM-04），效果全部来自
  SE/谱相似度/运动一致性/层关系/continuity 的 score 竞争（§8.4）；
  MOBILE_DECOY 稳定谱+真实机动模拟目标，JAMMER_CONFUSER 宽带高噪+运行时
  抖动假峰（谱一致性被稀释）；发射器有限库存/冷却/类型支持（§8.1/§8.5），
  激活延时前静默、激活记 DECOY_ACTIVATION 事件（§9.1）、有限寿命到期移出
  采样集；World 维护 targets+活动诱饵合成采样集（不污染玩家测量循环）。
  谱线细节：TorpedoAcousticProfile 补 tonal_lines_by_mode（QUIET/CRUISE/
  HIGH 各异谱线，运行噪声事件透传）；SeekerTrack 补 classification_match
  （return 谱线与锚点谱相似度 EMA）并以 w_c 进 score——稳定谱高、抖动假峰
  被稀释。`decoy_test` CM-01..05（发射/库存冷却寿命/同链采样/无类型泄露/
  固定 seed 拉锁复现）+ World 集成 + SPEC 谱线/分类。
- **Commit 9（§9，敌方随机出生/感知/Doctrine）**：新增 `scripts/ai/`——
  `enemy_spawn_generator.gd`（§9.4 方位带 + 三角距离 + 航向分布 + 深度带权重
  抽样；min_separation/尝试上限/fallback_spawn；独立派生 RNG 不消耗世界主
  RNG——玩家测量流随机序列零扰动）；`enemy_sensor_adapter.gd`（§9.5/§9.6
  内核边界：被动接触采样 + 声学事件单程截获，输出净化证据 noisy bearing/
  时间/频带/分类假设/置信度，绝无 range/位置/target_id；未探测绝不产证据 →
  AI 行为不变）；`enemy_track_manager.gd`（方位航迹：门限关联 + EMA + 质量
  命中涨/无证据衰减=不确定区扩大；TORPEDO 分类告警）；`enemy_doctrine_controller.gd`
  （§9.7 状态机 PATROL_PASSIVE→SUSPICIOUS→TRACKING→ATTACKING→EVADING→
  REACQUIRE；§9.8 公平性：反应延迟 3..15s 绝不同 tick 反应、概率化机动/换层/
  诱饵/反击、命令值接口限速率、BEARING_ONLY 宽扇区反击无隐藏距离）。World：
  场景 `enemy_spawn` 块装配（旧场景零行为变化）；敌方鱼雷独立 WeaponSystem+
  TorpedoContext（seeker 声源=本艇+蓝方诱饵）；双方鱼雷内核影子互听（玩家
  声呐可听到来袭鱼雷，敌方感知"来袭鱼雷"证据源）。`enemy_ai_test` AI-01..09
  + World 集成。
- **Commit 10（§10，Fuze/伤害证据/净化反馈）**：新增 `scripts/weapon/
  fuze_controller.gd`（§10.1 FuzeMode CONTACT/ACOUSTIC_PROXIMITY/
  MAGNETIC_PROXIMITY 简化几何版触发半径；§10.2 解保双保险 arm distance +
  min_time，SAFE 绝不起爆；与 Seeker/TargetSelection 彻底分离）+
  `scripts/acoustic/emission_sanitizer.gd`（§12.3 EventSanitizer：内核事件出
  玩法层前净化——敌方事件单程概率截获产 noisy bearing 告警证据，未探测绝不
  产证据；己方武器事件作本艇事实转录；§10.4 战果层级 classify_detonation
  纯函数 DETONATION_HEARD→PROBABLE_HIT→PROBABLE_KILL 只吃证据+玩家航迹方位，
  CONFIRMED_KILL 仅经 Debrief）。WeaponProgram 增 fuze_mode（快照携带）；
  WeaponSystem id_prefix（敌方 "ET"）。World 引信引擎：双方鱼雷 vs 对方 Truth
  几何触发 → EXPLOSION 声学事件（入总线可被双方截获）+ Truth 伤害（敌 sunk /
  本艇 damaged）+ 最近通过距离台账（_detonations，仅 _debrief_summary 调试
  通道）；player_evidence（净化证据队列）供告警 UI（Commit 11）。普通 UI 无
  即时 CONFIRMED KILL、无 target_id（UI-07/08）。`fuze_evidence_test`
  FUZE-01..07。
- **Commit 11（§11，武器 UI/海图/告警）**：新增 `ui/in_water_weapon_panel.gd`
  （§11.2 在水控制台：每枚鱼雷 mission/seeker/activeTX/authority/wire+剩余线长/
  ACT→CMD 深度/速度/燃料/锁定摘要；按钮 Course◀▶/Upper/Lower/Speed/Active ON-OFF/
  Autonomy/Wire-Only/Accept Trk/Cut Wire，不可用 disabled+原因）、
  `ui/countermeasure_panel.gd`（§8.5/§11.5 诱饵：类型支持/装填/库存/冷却/己方
  活动数 + MOBILE/JAMMER 发射，拒绝原因来自 CountermeasureSystem）、
  `ui/alert_panel.gd`（§11.5 告警：渲染 world.player_evidence 净化证据——时间/
  方位/置信度；己方武器爆炸经 classify_detonation 标注 PROBABLE_HIT/KILL；
  绝不显示 CONFIRMED KILL、绝无 target_id）、`ui/depth_band_display.gd`
  （§11.4 侧边深度条：Surface/层带/Bottom + OWN/TK/DCY 实际(实心)/命令(空心)
  标记，形状+文字双编码，绝不读敌方 Truth）。chart_view 叠加（§11.3）：线导
  虚线（只表示通信链）、搜索扇区边界、Seeker FOV（被动淡/攻击亮）、选中航迹
  不确定方位线（绝不画 Truth 目标）。weapon_panel 事件日志删除 target_id 显示
  路径（UI-07）。`weapon_ui_test` UIW-01..06。
- **Commit 12（§13/§14.7，集成与 CI 门禁）**：新增 `tools/s107_integrated_test.gd`
  全流程集成（固定 seed、纯无头、全 World 链路）：INT-A 完整击杀链——敌方随机
  出生（约束 + fallback）→ BEARING_ONLY 发射（程序无 range）→ 线导 300m 授权
  自主 → TIME 开主动 → Seeker 捕获/ATTACK/TERMINAL → 引信爆炸 → Truth 敌
  sunk → Debrief 台账 → 净化证据 classify_detonation 判 PROBABLE_*（绝无
  CONFIRMED/target_id）；INT-B 敌方反击链——Doctrine 自行 TRACKING→ATTACKING
  → 发射 → 玩家截获 POSSIBLE_LAUNCH_TRANSIENT/POSSIBLE_TORPEDO 告警 + 声呐
  听到来袭鱼雷（影子链测量增长）；INT-C 固定 seed 两次运行世界终态逐字段一致
  （§2.3）。配套：`EmissionSanitizer._make_fact` 本艇事实补 `bearing_deg`/
  `se_db`（己方武器状态合法信息的确定性声学接收计算，不消耗 RNG、无探测门限
  判定）——使 OWN_FACT 爆炸证据可进战果层级判定。`ci_tests.txt` 登记 24 项
  全量门禁。
- **评审修复 Patch A（数据正确性与身份）**：外部评审（腾讯文档 S1-07 复审）
  确认三处缺陷并修复——①P0-01 `EnemySensorAdapter` 把声源深度误当真方位写入
  证据（sample_passive 用 c.depth_m、intercept_events 用 src_depth）→ 改为
  NavUtils.bearing_to_true(observer→source) 几何真方位，深度只用于跨层传播
  损失；证据仍无 range/位置/target_id。②P0-05 `WeaponSystem.fire_program`
  硬编码 "T%02d" 忽略 id_prefix → 双方独立计数器都可产生 "T01" 冲突 → 改
  "%s%02d" % [id_prefix, _next_id]（玩家 T01/T02…、敌方 ET01/ET02…，全局
  唯一）。③P1-09 World 在 `enemy_weapons.step()` 已过滤 dead 后的数组里找
  dead → notify_torpedo_resolved 永不触发、doctrine 在水计数不释放、拒绝再次
  反击 → 改 step 前后按稳定 torpedo_id 求差、对消失 ID 恰好一次 notify；
  EnemyDoctrineController 增只读 `active_torpedo_count()`。回归
  `tools/patch_a_test.gd`（PA-01 深度≠方位刻意组合、PA-02 双系统 ID 唯一、
  PA-03 结算释放；AT-01/AT-02 对应）。
- **评审修复 Patch B（Seeker 与制导状态机）**：①P0-03 `SeekerTrack` 改标准
  alpha-beta 滤波（theta_pred = b + ω·dt；b' = theta_pred + α·r；ω' = ω +
  (β/dt)·r，wrap180/wrap360 保证跨界无跳变，|ω|≤25°/s 钳位）——旧实现漏预测
  项且把 residual/dt 当完整速度，恒速序列方位率被系统性拉向 0。新增惯性视线
  率 `los_rate_deg_s` = 相对方位率 + 载体自转率（torpedo 每步喂
  `_last_turn_rate_deg_s`）：kine 一致性与制导提前量都消费惯性率——相对率混
  入自转会把高机动目标/诱饵竞争与提前量全部带偏。`score` 的
  `score_se_ref_db` 校准 20→60（SE 40~75dB 常见段在 20 下全部饱和，声源强弱
  对竞争不可见）。②P0-04 `TorpedoSeeker.process_returns` 改扫描级
  Return×Track 代价矩阵 + 一对一分配（贪心代价升序、各用一次；代价 =
  w_θ·(Δθ/σ)² + w_r·(Δr/σ_r)² + 深度层罚，纯被动不产生距离项；绝对门限
  bearing_gate 保留）——旧实现逐条贪心允许同扫描双 return 重复更新同一航迹。
  ③P0-02 任务/权限/主动三维正交：`accept_seeker_track` 成功显式置 ASSISTED；
  `authorize_autonomy`（手动）无锁 → SEARCH 扇区扫掠；新增
  `_advance_program_autonomy`——主程序距离/时间自主触发属于主生命周期
  （wire_guidance_enabled=false 的无导线发射不再依赖 fallback 才能自主，
  AT-03 链路可达）；ATTACK 只在 seeker 实际拥有操舵权（AUTONOMOUS 或
  ASSISTED 已接受）时进入；集中迁移表 `_MISSION_TRANSITIONS` +
  `_try_mission()`（非法转换发 TRANSITION_REJECTED 结构化事件）。④P0-09
  主动链 ping_id 串联：每次 Ping 唯一 ping_id（"%s-P%03d"），TX_PING 事件/
  总线事件/pending echo/ACTIVE return/完成事件全带 id；回波调度加发射 FOV
  门（`schedule_active_echoes` 与被动同源 horizontal_beamwidth，扇区外不排
  程）；监听窗超时无回波 → LISTEN_COMPLETE_NO_RETURN（绝无"永远等待"），
  回波到达 → ECHO_RECEIVED。⑤P1-05 核心（Patch B 可测性前置）：鱼雷接收机
  自噪与辐射噪声/潜艇级 own_noise 分离——`TorpedoAcousticProfile.
  receiver_self_noise_db(speed)`（base 55 + 0.9/kn）、
  `EnvironmentModel.effective_noise_db_with_self`、AcousticService passive/
  active SE 增可选 self_noise_db 覆盖（-1 = 旧行为，同一方程仅换噪声项）。
  回归 `tools/patch_b_test.gd`（PB-01 alpha-beta 恒速+跨界/PB-02 一对一关联/
  PB-03 accept→ASSISTED/PB-04 authorize→SEARCH 扫掠/PB-05 无导线程序自主/
  PB-06 WIRE_ONLY 不 ATTACK/PB-07 主动链 ping_id+FOV+NO_RETURN；AT-03..07/
  AT-18 子集）。

- **Patch C（评审统一声场，2026-09-04）**：
  - P0-06 统一声场（阶段 1）：World `_acoustic_scene_emitters/_acoustic_scene_acs`
    内核侧注册表（双方在水鱼雷影子 + 活动诱饵）；`main_ui._op_step` 用同一
    合并声场喂 OperatorSonar——auto_measurements=false 的 UI 路径也能按概率
    探测到鱼雷（BB 峰/NB/测量候选/告警同一物理到达）。武器采样集含本艇声源。
  - P1-04.5：OperatorSonar.display_amp_db 显示对比度下限 1.5dB（已探测样本
    SE<=0 不再隐形；弱接触低幅度+高抖动表达，不改 P_d）。
  - P1-06：`_spectral_features` 逐谱线独立声学（TL(f)+跨层+N_eff 含鱼雷接收
    自噪+P_d 丢线+频偏/幅度噪声），绝不复制 Truth 声纹；`truth_range_m` 仅
    内核谱线计算用，绝不入 return。
  - P1-07：主动回波测量历元统一——pending echo 快照发射几何，反射历元 =
    emit + R/c（鱼雷按发射航向/航速外推），方位/SE/测距全用反射历元；
    return 携带 timestamp（反射）/available_time（到达）。
  - P1-12：contact_tokens 内核边界安全过滤（OWN/HOSTILE/FRIENDLY）；本艇
    return 可在传感器内部产生但 torpedo 资格过滤拒绝（CONTACT_REJECTED_
    SAFETY 事件、不进航迹/制导）；引信独立安全保险 FUZE_SAFETY_INHIBIT
    （对发射方本侧平台绝不起爆，与 seeker 过滤互相独立）。
  - 回归 `tools/patch_c_test.gd`（PC-01 统一声场含敌雷+UI 出峰/PC-02 显示
    下限/PC-03 谱线净化不复制 Truth/PC-04 回波历元/PC-05 己方可见但安全）。

- **Patch D（评审威胁证据与地图，2026-09-04）**：
  - P0-07 ThreatBearingEvidence：EmissionSanitizer 的 INTERCEPT 证据新增
    `evidence_kind`（LAUNCH_TRANSIENT/RUNNING_NOISE/ACTIVE_PING/DETONATION/
    DECOY）、`available_time`、`sensor_id`、接收时刻本艇位置快照
    `observer_e_m/observer_n_m`——地图 LOB 起点用接收时快照，本艇机动后不漂移
    （AT-09）。绝不携带 Truth 位置/range/target_id（AT-10 子集）。
  - P1-11 ThreatTrackManager：按时间（≤45s）、方位率外推创新门（≥3σ 且
    ≥12°）与证据种类升级链（TRANSIENT→NOISE→PING 只升不降）把威胁证据关联
    到同一 ThreatTrack（track_id 写回 `threat_track_id`），抑制每秒一条
    POSSIBLE_TORPEDO 告警的洪泛；World.load_scenario 重置。
  - P0-10 SeekerBeamState 单一真源：`SeekerBeamState.new_from(tp)` 从武器
    权威状态生成扇区（被动/发射/接收半角 = 0.5×horizontal_beamwidth_deg，
    中心 = 实际艏向 course_deg 绝不随命令瞬移，search_center/half、tx_state、
    receiver_state、authority、steering_source、display_range_mode=SYMBOLIC）。
    适配器被动门/主动发射门/主动接收门与 ChartView 绘制读取同一参数（AT-19）。
  - P1-02 地图鱼雷指示：ChartView 鱼雷标签用真实 torpedo_id（不用数组序号）；
    ±σ 楔形用航迹真实方差 sqrt(bearing_var)；主动扇区脉冲/颜色由 tx_state
    驱动（PINGING 亮红脉冲/WAITING_TRIGGER 橙虚线/COOLDOWN 暗红点线/OFF 不画
    "正在照射"），被动接收扇区冷色青虚线；auto_frame 纳入鱼雷轨迹与威胁 LOB；
    命中测试 `torpedo_click_points/_on_click`（点击选中/空白取消，
    torpedo_selected 信号）；`threat_click_points` 点击威胁 LOB 发
    threat_selected，AlertPanel 同 evidence_id 行高亮（交叉联动单向，
    反向属 Patch E）。
  - 地图威胁图层：`ChartView.set_threat_evidence(player_evidence, now)`，
    有限长度 LOB（6km）+ ±2σ 不确定扇形，颜色/线型按证据种类，透明度随龄期
    半衰（300s）衰减；每 ThreatTrack 只保留最新一条防闪烁；layers.threat 开关。
  - 回归 `tools/patch_d_test.gd`（PD-01 观察点快照 AT-09/PD-02 ThreatTrack
    关联升级链与洪泛抑制/PD-03 扇区单一真源+边界内外与正后目标门 AT-19/
    PD-04 海图输入数据与命中测试/PD-05 证据与 track 无 Truth 泄漏）。
- **Patch E（评审武器 UI 与人机工效，2026-09-04）**：
  - P1-01 五正交状态逐帧呈现：武器卡每帧从权威状态读取 Recv/TX/Trk/Auth/
    Steer 五行（经 SeekerBeamState 派生 steering_source），不等 seeker
    phase 变化才刷新。命令拒绝显示具体原因：Torpedo 新增 UI 命令门
    `_cmd_gate()` + `last_cmd_reject_reason`（WIRE CUT / WIRE BROKEN /
    LAUNCHING / INVALID STATE / NO CANDIDATE），武器卡显示
    `CMD rejected (<原因>)`，不再统一 rejected (CONNECTED)。内核内部检查
    继续用无副作用的 `_wire_accepts_command()`。
  - P1-03 侧栏与武器卡生命周期：新增 `UiContract`（侧栏宽度契约
    min=300/preferred=340/max=420 + `sidebar_clamp_x` 每帧钳制；场景解析）；
    侧栏 VBox 不再 EXPAND_FILL，动态 Label 全部 autowrap；武器事件日志
    一行一事件（废除 " | " 拼接）；事件文案映射与真实事件名一致
    （SEEKER_PHASE/TRACK_ACCEPTED/ACTIVE_TX_PING/ECHO_RECEIVED/
    LISTEN_COMPLETE_NO_RETURN/FUZE_ARMED...），删除失效的 ACQUIRE/ENABLE
    特判；InWaterWeaponPanel 动态卡只在专用 `_cards` 容器重建（header 保留，
    修复重建后标题消失）；无候选时 Accept Trk disabled + tooltip 原因；
    SeekerTrack.to_summary 新增 `bearing_sigma_deg`（候选卡显示真实方差）。
  - P0-08 combat scenario 入口：新增 `tools/scenarios/s1_combat.json`
    （随机敌方出生 enemy_spawn + doctrine 反击/诱饵 + 深度层 + 拖曳阵 +
    主动声呐）；默认场景保持 stage1_basic_passive 不静默变更，
    `SONAR_SCENARIO=s1_combat` 显式切换（UiContract.resolve_scenario_name）。
  - P2-01 搜索扫掠连续初始化：进入 SEARCH 时记录 enter 时刻并把扫掠相位
    偏置到当前航向（SNAKE 取三角波第一分支、CIRCLE 取最近角，中心外夹到
    扇区边界），离开 SEARCH 重置——不再跳到全局 sim_time 相位。
  - P2-02（简化明示）：wire `paid_out_m` 语义为「累计放缆」（鱼雷绕回不收
    缆），文档化为有意简化；如需松缆/收缆另建 cable state。
  - P2-03（简化明示）：被动瞬态当前同 tick 到达、主动回波按 R/c/2R/c 传播
    （P1-07 已实现历元）；证据统一携带 available_time，抽象边界已标注。
  - 回归 `tools/patch_e_test.gd`（PE-01 拒绝原因+五正交行/PE-02 header 保留
    +Accept 门控+日志格式/PE-03 s1_combat 装配+UI 同配置+场景选择器/
    PE-04 扫掠连续初始化/PE-05 侧栏契约/PE-06 摘要 sigma）。PB-04 断言随
    P2-01 语义更新（单步持续推进 + 20s 累计净漂移 >5°，替代跳相位伪影阈值）。
- **Patch F（评审可靠性与完整场景，2026-09-05）**：
  - P1-08 swept 引信：FuzeController 新增 `swept_min_distance_m/_h_m`、
    `swept_closest_t` 与 `check_trigger_swept`——对每个 contact 用上一 tick
    相对位置快照做 [t0,t1] 连续最近通过判定，消除 40/50kn 每 tick 10-13m
    逐点采样穿越漏触发；水平 swept ≤ 触发半径且 CPA 时刻垂直距离 ≤
    `FUZE_VERTICAL_GATE_M`(25m，层带粒度近似) 才触发——深度层语义纳入引信
    （AT-15）。World 维护 `_fuze_prev_tp/_fuze_prev_contact` 快照台账并随
    load_scenario 重置；swept 同样用于最近通过台账与安全保险检查。
  - 发射 hold 深度修复（P1-08 排查副产物）：Torpedo.launch 只写
    `commanded_depth_band` 未写 `commanded_depth_m`，`_advance_vertical`
    恒早退——层带 hold 从未执行、鱼雷停在发射深度。补上 hold 深度命令。
  - 深度带归向（P1-08 配套）：SeekerReturn 新增 `depth_band_hint`
    （适配器在测量边界内对接触深度的层带粗分类 UPPER/LOWER，不含精确
    Truth 深度）；SeekerTrack 保留最新提示；制导拥有操舵权时向提示层带
    垂直机动（Vz_max 限速）——异层目标自此可被合法攻击，否则 25m 垂直门
    使跨带杀伤链永不成立。
  - P1-10 长局刷新：OperatorSonar 新增单调 `waterfall_seq`（每新行递增），
    OperatorPanel 比较 size+seq（封顶 600 行后仍持续刷新）；AlertPanel 改
    比较最新 `evidence_id`（封顶 256 条后仍持续更新）（AT-14）。
  - AT-16 声学标定包线：新增 `tools/calibration_envelope_test.gd`——固定
    环境（stage1_basic_passive）、同层/跨层、QUIET/CRUISE/HIGH Monte Carlo
    被动 P_d(R) 曲线（BB+逐谱线独立采样）与主动曲线（seeker 12kHz SL195
    TS14、接收机自噪@40kn）；断言固定 seed 复现、QUIET<CRUISE<HIGH 次序、
    跨层 < 同层、R50≥R90，并冻结设计区间（被动 QUIET 1.5-6km / CRUISE
    6-18km；主动 R50 150-1200m / R90 50-900m）。实测：被动 R50 2400/11800/
    ≥20000m（同层），跨层 7400m；主动 R50=500m、R90=300m。改标定须显式
    更新区间与本节。
  - AT-17 端到端（来袭半环）：`patch_f_test` PF-03 以 s1_combat 正式场景 +
    `auto_measurements=false`（与 UI 相同配置）验证 玩家发射 → 敌截获
    LAUNCH_TRANSIENT → doctrine 反击 → 玩家收到 INTERCEPT 证据 +
    ThreatTrack，全程无 Truth 泄漏；s1_combat doctrine 显式
    `evade_trigger_probability: 0`（反击优先 doctrine）。发现→TMA→发射→
    命中半环由 `s107_integrated_test` INT-A/B 覆盖，两测试合成 AT-17。
  - 回归 `tools/patch_f_test.gd`（PF-01 swept 纯函数+穿越触发+半径外不误触
    +垂直门/PF-02 瀑布与告警封顶后持续刷新/PF-03 e2e 反击链）与
    `tools/calibration_envelope_test.gd`（CAL-1..9）。WIRE-02h 断言随发射
    hold 修复更新（按实际起点动态下限）；FUZE-05 在新垂直语义下保持原
    几何（敌雷向层带 hold 机动后同带命中）。
- **Patch G（REQ 鱼雷制导链路重构，2026-09-05）**——目标不是保证必中，
  而是"捕获—接管—制导—保持航迹—引信—声学反馈"逻辑正确且每次脱靶可
  解释；禁止用提转率/扩 FOV/扩引信半径/提源级掩盖机制错误：
  - REQ-01 四轴状态分离：Seeker Phase（SEARCH/ACQUIRING/TRACKING/COAST/
    LOST/REACQUIRE，新增 COAST）/ Guidance Authority / Steering Source /
    Mission 各自独立；进 ATTACK 需同持有效航迹 + ASSISTED/AUTONOMOUS +
    航迹达捕获阈值，且**每 tick 评估**（TRACKING 可发生在 WIRE_ONLY 期间、
    之后才授权自主——只在相位变化时评估会永久滞留 WIRE_RUN）；
    WIRE_ONLY+TRACKING 仅表示 TRACK AVAILABLE。
  - REQ-02 滤波：SeekerTrack 标准 alpha-beta（预测项+wrap 跨界+率限幅
    ±25°/s）；`min_update_dt_s`(0.05) 门——dt 过小只更新位置不更新率
    （结构性禁止 residual/dt 尖峰）；主动测距同步 alpha-beta 滤波
    `range_rate_m_s`。
  - REQ-03 机会计龄：miss 不再按仿真 tick/壁钟扣分——被动扫描完成
    （`notify_passive_scan`，FOV 内且超过 passive_miss_window_s 每窗口一次）
    与主动监听窗结束无回波（`notify_active_miss`，每次 Ping 恰好一次）
    是仅有的有效测量机会；COAST 超时 = Ping 间隔 + 监听窗 + 余量
    （`coast_timeout_s` 默认 interval+34s）。仅 8s 一次主动回波可稳定
    保持航迹（RO-05）。
  - REQ-04 制导律：废除固定 12s 提前量单算法。TorpedoGuidance 新增
    `intercept_turn_rate_deg_s`——中段主动测距有效时比例导航
    `Kp·err + N·(v_closing/v_t)·λ_dot`（λ_dot 项限幅 ±12°/s）；纯被动
    `Kp·err + Kd·λ_dot`；近程（range ≤ `terminal_switch_range_m`=300m）
    切纯追踪（PN 的 LOS 率在过靶前发散，继续用会 bang-bang 抖振导致
    擦过——标定 Kp=1.2/N=3.0/Kd=3.0/Kp_t=2.0）。输入只有净化航迹 +
    自身状态，绝不读 Truth。
  - REQ-05 tick 顺序：权限推进 → 主动发射机 → 被动采样+到点回波 →
    Seeker 相位 → 制导命令 → 有限转率转向 → 垂直 → 平移（引信 swept 由
    World 在运动后统一判定）；捕获并取得权限后同一 tick 即转向（≤1 tick）。
  - REQ-06 FOV/COAST：目标预测方位离开接收 FOV → COAST（按最后方位+率
    短时预测惯性保持），超时才 LOST；重进覆盖 → REACQUIRE；LOST/REACQUIRE
    重锁要求**脱锁后有新测量**（`last_update_time > phase_since`，禁止对
    陈旧航迹幽灵重锁 → 冲过目标后必然走向 SEARCH 重搜，不无限 COAST/
    REACQUIRE 死循环）；被动/主动 FOV 半角独立配置
    （`passive_fov_half_deg`/`active_fov_half_deg`，旧配置回退 beamwidth/2）；
    扇区中心恒为实际艏向（SeekerBeamState 单一真源不变）。
  - REQ-07 转弯性能：`omega_max = min(机械限 6°/s, 横向过载限/速度)
    （`max_lateral_accel_m_s2`=4.5，40kn 时 12.5°/s 不绑定）；诊断字段
    `commanded/actual_turn_rate_deg_s`、`turn_saturated`；禁止提转率掩盖。
  - REQ-08/验收14 脱靶原因：TorpedoMissReason 纯函数按优先级判定
    NO_GUIDANCE_AUTHORITY / TURN_RATE_SATURATED / ACTIVE_TRACK_AGED_OUT /
    TRACK_LOST_OUTSIDE_FOV / TRACK_FILTER_DIVERGED /
    FUZE_MISSED_BETWEEN_TICKS / FUEL_EXHAUSTED，随死亡事件 detail 下发
    Debrief（FUEL_OUT 短路为 FUEL_EXHAUSTED；命中为空）。
  - REQ-09 鱼雷声谱：`_sync_torpedo_shadows` 从 `_advance_enemy_ai` 移出、
    tick 主路径无条件调用——无敌方 AI 场景玩家鱼雷也进入统一声场（旧实现
    enemy_ai==null 提前返回导致玩家雷声学影子永不产生）；死亡鱼雷影子
    自然消失（is_dead 过滤）；瀑布窄带频段可切换
    （`OperatorSonar.set_nb_band`：LOW 0-500 / MID 500-3000 / HIGH 8000-
    16000 Hz，CRUISE 540/1080、HIGH 660/1320 预设谱线不再被 0-500 过滤，
    OperatorPanel 下拉切换）；EmissionSanitizer 敌方瞬态证据增加单程传播
    时延（`_pending_delayed` 在途台账，t_emit + R/c 后才结算，验收12），
    出管/电机/Ping/爆炸证据全部按声速到达；TORPEDO 分类仍走观测特征
    （威胁证据 source_class_hypothesis，绝不读 Truth 类型）。
  - 结构：torpedo.gd 超 1200 行上限 → 拆出 `torpedo_emitter.gd`（声学
    广播子控制器：motor_start/active_ping/running_noise 的 bus 写入收敛）、
    `miss_reason.gd`（脱靶原因纯函数）；seeker cfg 默认值收敛至
    `TorpedoGuidance.default_seeker_cfg`；扫掠相位求偏移收敛至
    `TorpedoGuidance.search_phase_offset_for`。
  - UI：在水武器卡新增 命令/实际转率+SAT 徽标、Desired（PN/期望航向）、
    引信状态+最近通过距离、声学模式+下一发 Ping 倒计时、航迹距离/距离率
    （第三部分遥测清单）；普通 UI 无 Truth（既有纪律不变）。
  - 回归 `tools/req_overhaul_test.gd`（RO-01 WIRE_ONLY 不转向/RO-02 Accept
    即 ASSISTED+下一 tick 转向/RO-03 自主接管与无航迹进 SEARCH/RO-04 滤波
    收敛+跨 0°/RO-05 仅主动回波保持航迹/RO-06 1500m-10kn 横向目标拦截/
    RO-07 FOV-COAST-REACQUIRE/RO-08 冲过后重搜/RO-10 无敌 AI 统一声场/
    RO-11 频段切换/RO-12 传播时延/RO-13 脱靶原因）。既有测试随语义更新：
    torpedo_track_test SEEK-08/10/11b 按 REQ-03 改为机会计龄驱动；
    patch_d_test PD-01/05 消费点让出传播时延；s107 INT-A/B、fuze_evidence
    FUZE-05 命中后留传播窗口再收证据；decoy_test CM-05c 容差 10→15°
    （PN 饱和圆弧段滤波滞后，主导性判定不变）。

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
>
> **覆盖/挡板强制执行（S1-03C-P1-03）**：SensorArray 的 `coverage_sector` /
> `baffle_sector`（相对艏向，经 `coverage_start_deg/coverage_end_deg/
> baffle_start_deg/baffle_end_deg` 声明）不再只是配置数据——自动被动链
> `MeasurementGenerator.generate_passive()` 与主动 Ping `World.issue_ping()`
> 都经 `SensorArray.in_coverage()` 门禁：覆盖外/挡板盲区内目标恒 miss。
> 门禁在 pd 采样之后判定，RNG 消耗序列不变（全向 0..360 场景零行为变化）。

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

**发射扇区（S1-03C-P1-03）**：主动阵不是全向的——`own_ship.active_sonar` 可
声明 `coverage_start_deg/coverage_end_deg/baffle_start_deg/baffle_end_deg`
（相对艏向，未声明 = 全向 0..360 无盲区），与 SensorArray 覆盖模型同源。
`issue_ping` 在**发射时刻固化各目标相对方位**，只登记扇区内目标的在途回波；
扇区外目标绝不产生回波（监听窗诚实到期 → NO_RETURN），到达时刻不补判。

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
