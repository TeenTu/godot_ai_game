# Sonar 操作验证手册（Stage 1-3，TMA 可视化重构版）

> 线上地址：https://teentu.github.io/godot_ai_game/sonar/
> 本地运行：`godot --path games/sonar`（Godot 4.5）

---

## 1. 界面布局

```
┌──────────┬──────────────────────────────┬───────────────────┐
│ 方位盘     │       海图（ChartView）        │  控制面板（可滚动）   │
│ Bearing  │  - 网格（2000m/格）           │  - 标题            │
│ Display  │  - OWN 蓝三角（本艇）          │  - Pause/Mark      │
│ 220px    │  - 本艇历史轨迹（淡蓝线）       │  - Speed 倍速      │
│          │  - 历史 LOB 扇形束             │  - Show Truth      │
│          │    （时间衰减+±2σ扇区，        │  - 状态栏/接触列表   │
│          │     离群测量画虚线）           │  - 本艇机动区       │
│          │  - 拟合轨迹（粗实线+白色       │  - Auto Fit TMA    │
│          │    时间刻度圆点）             │  - 状态机详情面板    │
│          │  - 备选解（低饱和虚线+权重）    │  - Trial 编辑区     │
│          │  - TRIAL 绿点+速度箭头        │  - Dot Stack       │
│          │  - 当前位置不确定圈(1σ/2σ)     │                    │
│          │  - SYSTEM 黄圈               │                    │
│          │  - Truth 红方块（调试）        │                    │
├──────────┴──────────────────────────────┴───────────────────┤
│ Bearing-Time 图（BearingTimePlot，150px）                      │
│  - 实测方位点+±1σ误差棒（按 track 着色）                       │
│  - 最优解预测方位曲线（粗实线）/备选解（虚线）                   │
│  - 本艇转向时刻竖线；方位跨 0/360 自动展开防跳变                 │
└─────────────────────────────────────────────────────────────┘
```

## 1.5 可视化重构要点（本次新增）

- **接触选择**：Contacts 列表可点击，Auto Fit 只作用于选中接触（Selected: S01 行
  同步显示 B/R/C/S）；未选中的接触在海图上降到 alpha 0.12。
- **LOB 减载**：默认只画 ≤24 条代表性 LOB（最新 4 / 最旧 2 / 观测腿边界 / 均匀
  抽样）；σ 扇区只在悬停或选中测量时显示；离群点红虚线 + X 标记；
  "All LOB History" 开关可展开全部。
- **海图相机**：滚轮缩放（1~60 km）、左键拖拽平移、Reset View / Auto Frame；
  左下比例尺、右上北向标记、自适应 km 网格；右下图例。
- **拟合轨迹**：白 3px + 橙描边；≤12 个 mm:ss 时间刻度（可点击联动残差图）；
  备选解 A/B/C 编号 + 三种虚线；Trial 青菱形、System 紫双环。
- **Bearing-Time 图**（240px）：局部动态纵轴（跨北连续展开），可切 360° Overview；
  悬停测量 → 海图联动显示 o_i / p_i / z_i / θ̂_i / e_i / e_iσ。
- **残差图（新增）**：e_i 随时间分布，deg/sigma 轴点击切换，±1/2/3σ 带，
  RMS/bias/max/used/rej 统计；离群点红 X。
- **不确定度**：4x4 协方差外推（P_now = F P Fᵀ + Q），海图画 95% 置信椭圆；
  rank<4 / cond>1e4 / MULTIMODAL 时不画椭圆。
- **性能**：LOB / BT / 残差数组只在「新测量 / 新拟合 / 选择或图层变化」时重建。

截图回归（7 状态，带渲染环境运行）：
```bash
godot --path games/sonar --script res://tools/ui_regression.gd
# 输出 tools/regression/{NO_FIT,CONVERGED,MULTIMODAL,INSUFFICIENT_GEOMETRY,
#   STALE,OUTLIER,NORTH_CROSSING}.png
```

## 1.6 Sonar Operator Layer（阶段三收尾）

- **信息链纪律**：Truth 只进入声场与阵列采样（OperatorSonar.update）；
  对外输出仅操作员视角数据（瀑布行/分类/DEMON 估计），绝不暴露目标真值。
  Measurement 只由 玩家 Mark / 已分配 Tracker / Autocrew 产生。
- **阵列**：BOW（全向，艉部 ±30° 盲区）/ FLANK（左右舷 ±55..125°，高增益高精度）/
  TOWED（相对阵轴前视 ±100°，低频增益最高）；右上 Operator 区可切换，覆盖外无检测。
  多扇区阵列（FLANK）方向性增益取"所有覆盖扇区中最优一支"（S1-01 回归）。
  覆盖/盲区同样在**自动测量链与主动 Ping 链**强制执行（S1-03C-P1-03）：
  自动被动测量经 `SensorArray.in_coverage()` 门禁（覆盖外恒 miss）；
  主动 Ping 发射时刻固化各目标相对方位、只登记发射扇区内回波（`active_sonar`
  可配 `coverage_start_deg/.../baffle_end_deg`，未配 = 全向，行为不变）。
- **TOWED 可控长度拖曳阵（S1-03，批次2+ 重做）**：状态机
  `STOWED ↔ STREAMING ↔ HOLD_PARTIAL ↔ RETRIEVING`——实际缆长 ACT 与命令缆长 CMD
  分离，`stream/hold/retrieve` 任意长度可停可反向，缆长按固定收放速率（m/s）逼近命令；
  面板提供 Stream/Hold/Retrieve 按钮 + 长度滑条（25/50/75/100% 预设），
  状态行同时显示 ACT/CMD/阵航向/可用度。部分长度真实参与声学：有效孔径比例
  `q_L=clamp((L−L_dead)/(L_full−L_dead),0,1)` 决定增益损失，回收第一帧起性能连续
  下降（绝不瞬间静音），`L≤L_dead` 或 STOWED 时阵无声学孔径、严格无 TOWED 测量。
  阵轴对本艇转向一阶滞后收敛，tau 随实际缆长插值并按本艇实际航速标定（慢速更飘、
  快速拖直）；TOWED 观察站位 = 阵列声学中心 `p_array = p_own − d_center·[sin ψa, cos ψa]`。
  物理由 `scripts/towed_array.gd`（纯逻辑，可无头测）驱动，经 `TruthEntity.advance`
  每步注入实际航速推进；本艇未配置 `own_ship.tow` 时 TOWED 选项禁用
  （`towed_available()=false`，无"跟艇+满可用"的虚构回退）。
- **TOWED 左右舷镜像歧义（S1-03A/S1-06）**：单线阵对阵轴两侧等角响应，每次到达
  生成共享 pair_id/SE/噪声样本的 A/B 候选峰（`θ_A=ψa+β`、`θ_B=ψa−β`，消歧前对玩家
  等价、不标真假）。玩家点击镜像峰时 `create_mark_group` 产生一组两个 Measurement，
  进同一 Track（不建第二个目标、不双倍计数）。TMA `solve_auto` 按 branch 过滤为
  A/B 两套观测分别拟合，softmax 出分支权重；仅当可观测性合格（rank≥4 且 legs≥2）
  且最佳权重≥0.9 才置 `mirror_resolved=true`，否则状态 `AMBIGUOUS_LR`（落选分支
  保留在 alternatives 可回看）。直航观测无法消歧；机动后分支代价拉开才消歧。
- **瀑布图**：Broadband（方位-时间，点击游标 Mark）、Narrowband/LOFAR
  （频率-时间 + DEMON 谐波标记联动）、DEMON 包络谱。
- **概率分类**：观测（桨叶率/音线数/响度）与情报库模板 softmax → MERCHANT /
  WARNOTHINGSHIP / SUBSONAR 概率。
- **DEMON 测速**：轴转速+桨叶数估计；航速用情报库 kn_per_br_hz 先验换算，
  带 sigma，仅作 TMA 软约束（confidence>0.3 且 sigma<6 才注入 solve_auto）。
- **默认关闭自动 Mark / 建 Track**；Autocrew 复选框可开（PD≥0.85 自动 Mark）。
- **无头验收**：`tools/operator_test.gd` —— 玩家不知 Truth：噪声发现(169s) →
  宽带 41 次 Mark → 窄带识别 MERCHANT → DEMON 测速 12.0±3.6kn(真值12) →
  本艇 +70° 机动两腿 TMA CONVERGED → 提交 System Solution → 全部断言 PASS。
  运行：`godot --headless --path games/sonar --script res://tools/operator_test.gd`
- TOWED 可控长度拖曳阵无头验收（S1-03/S1-03A/S1-06）：`tools/towed_test.gd` ——
  T1 STOWED 初态 / T2 STREAM·HOLD·RETRIEVE 任意长度可停可反向 / T3 孔径 q_L 连续
  （回收不瞬间静音）/ T4 阵轴滞后 tau 随缆长+实际航速标定 / T5 阵心观察站位 /
  T6 无硬件禁用（usable=0、无峰）+ own.advance 集成 / T7 镜像对共享 pair_id·SE·
  噪声且 θ_A+θ_B=2ψa / T8 Tracker 镜像候选不重复计数 / T9 TMA 直航不消歧·机动
  后分支消歧（胜者逼近真值），全部确定性 PASS。运行：
  `godot --headless --path games/sonar --script res://tools/towed_test.gd`
- 0.2 六条回归（S1-01）无头验收：`tools/fix_batch1b_test.gd` R1 多扇区增益 maxf /
  R2 TRUE 瀑布源列恒 -180..180 / R3 历史行 Mark 携带该行时间·艏向·站位 /
  R4 create_mark 峰匹配 canonical frame（TRUE 输入先转显示 frame 再比峰）。
- 统一声学引擎 + 命令动力学无头验收（G-03/S1-04/S1-02/G-05）：
  `tools/dynamics_test.gd` —— D1 命令转向速率限制+完成清命令+跨 0/360 /
  D2 命令加减速限制 / D3 无命令直写 actual 兼容（AI 目标/旧测试）/
  D4 SensorArray↔AcousticService 公式逐位等价（G-03 单一实现）/
  D5 环境噪声表字符串键匹配+频率线性插值（不恒回退 60dB）/
  D6 OperatorSonar 用 EnvironmentModel TL（含吸收项）解析对照 /
  D7 弱目标概率探测间歇出现（无 SE<=0 硬门限）/
  D8 谱图背景 AR(1) 时间相关噪声 texture（非固定纯色，行间均差<2dB）。
  运行：`godot --headless --path games/sonar --script res://tools/dynamics_test.gd`
- 主动声呐 Ping 无头验收（S1-04B PingSession 单在途状态机）：
  `tools/ping_test.gd` —— P1 冷却（连发被拒、冷却后恢复）/ P2 **回波按
  τ=2R/c 延迟到达**（声速 1500m/s，8km 目标 next_echo_in≈10.7s；半途 take
  为空、到点才 detected+range≈真距）/ P3 极远目标无回波（SE 极负不产
  Measurement）/ P4 回波到点才 append 测量流（发射瞬间不 append）/ P5 摘要
  字段完整 / P6 场景 active_sonar 配置覆盖（含 sound_speed_m_s → τ 变）/
  P7 无目标诚实监听窗口→NO_RETURN / P8 无硬件（无 active_sonar 且无 active
  阵）→ UNAVAILABLE，Ping 被拒（REQ-20）/ P9 摘要方位≈几何真方位 /
  P10 冷却已过但回波未归 → 再 Ping 被拒（单在途 REQ-16/17）。运行：
  `godot --headless --path games/sonar --script res://tools/ping_test.gd`
- 主动 range 进 TMA 数据链无头验收（S1-04B 评审 TEST-S1-04B）：
  `tools/ping_tma_integration_test.gd` —— R08 fit_meas_dict 透传
  range/range_sigma / R08b 解算器把带 range 测量展开为 RANGE 残差行且残差
  行数与测量严格配对 / R10 单腿纯方位 → INSUFFICIENT_GEOMETRY，同几何 +
  尾部主动 range → 可锚定（误差 <800m）/ R11 Tracker 方位+距离双门控 /
  R19 往返测距同源（measured_range 以发射时刻 range_ref 为基准，τ 内位移进
  range_sigma）/ R03 Measurement.to_dict() 无 Truth id / E2E 控制器
  request_ping→回波喂 Tracker 建 P 接触→on_echo_hits 携带 Track→REFIT 后
  摘要含 RANGE AIDED。运行：
  `godot --headless --path games/sonar --script res://tools/ping_tma_integration_test.gd`
- 注意：main_ui 默认 `world.auto_measurements = false`（operator 模式，主动
  回波由 ActivePingController 喂 Tracker）；旧冒烟/回归工具
  （play_test / ui_regression）在 UI 就绪后显式开回 true 模拟 Autocrew 模式。

---

## 2. 验证流程（推荐顺序）

### 步骤 0：打开游戏
- 浏览器打开线上地址，应看到「Submarine Sonar / TMA」标题和完整 UI。
- **预期**：无报错黑屏，三栏布局齐全，右侧面板可滚动。

### 步骤 1：确认仿真自动运行
- 不点任何按钮，等约 10 秒。
- **预期**：
  - 状态栏 `Time` 持续增长（默认 2x 倍速）。
  - 海图 OWN 蓝三角从原点出发缓慢移动（本艇初始航向 0°、航速 4kn）。
  - 方位盘出现一条彩色接触线（S01），海图出现对应的黄色 LOB 射线。
  - 接触列表显示 `S01 Brg ~45°`。

### 步骤 2：确认测量积累（验证接触关联）
- 继续等，让 `Meas` 计数增长（每 2 秒 +1 条测量）。
- **预期**：`Contacts: S01 Brg X° (N meas)` 里的测量数 N 持续增加，S01 是唯一接触。

### 步骤 3：自动拟合 TMA（核心验证）
- 点击右侧 **Auto Fit TMA** 按钮（可能需要向下滚动面板）。
- 求解器对全部历史测量做全局多初值 + 稳健拟合，结果写入 **Trial**（不会自动进入 System Solution）。
- **预期**：
  - 状态面板出现状态机结果之一：
    `CONVERGED`（收敛）/ `PROVISIONAL`（暂定）/ `INSUFFICIENT_MEASUREMENTS`
    （测量太少）/ `INSUFFICIENT_GEOMETRY`（单观测腿不可观测）/ `MULTIMODAL`
    （多解）/ `MANEUVER_SUSPECTED`（疑似目标机动）/ `BOUNDARY_HIT`
    （解撞搜索边界）/ `STALE`（数据过旧）。
  - 面板同时显示：RMSE、可观测性 rank/cond、位置/航速不确定度、
    观测腿数 legs、备选解权重、剔除离群数 rej。
  - 海图出现拟合轨迹（粗实线）+ **白色时间刻度圆点**（刻度必须落在对应 LOB 上）
    + 当前位置不确定圈（1σ/2σ）+ 600s 外推预测。
  - 存在备选解时（权重 ≥0.02）海图显示低饱和虚线轨迹及权重标注。
  - 底部 Bearing-Time 图出现实测点与模型预测曲线。
  - TRIAL 绿点被自动拟合结果填充；Dot Stack 显示 `RMS x.xx° (N pts)`
    （只用 inlier 测量，离群点不计入）。

> ⚠️ 注意（预期行为，非 bug）：
> - 本艇不机动（单观测腿）时纯方位 TMA 不可观测，状态应为
>   `INSUFFICIENT_GEOMETRY` 或 `MULTIMODAL`，且**不会给出虚假的小误差椭圆**
>   （协方差仅在单峰且可观测时输出）。
> - 多解时不会武断选一个，而是列出备选假设及权重，需本艇机动收窄。

### 步骤 4：本艇机动（验证歧义收窄能力）
- 在 **Own Ship Maneuver** 区点击「Right 5°」数次（或直接改 Own Course），
  再点「+2kn」一两次。
- 继续跑 30~60 秒，让新测量积累（形成第二观测腿）。
- 再次点击 **Auto Fit TMA**。
- **预期**：
  - 状态面板 `legs` 变为 ≥2（累计基线法按本艇位移方向变化计数）。
  - 海图 OWN 三角和轨迹明显转向/弯折；Bearing-Time 图出现本艇转向竖线。
  - 拟合不确定度（Pos ±xx m / Spd ±x.x kn）相比单腿显著收窄。
  - 若目标本身在转向，状态会变为 `MANEUVER_SUSPECTED`——
    此时不做离群剔除（连续同号大残差是机动特征，不是坏点）。

### 步骤 5：Show Truth 调试（验证 Truth 隔离）
- 勾选 **Show Truth (debug)**。
- **预期**：海图出现 **红色方块**（真实目标位置，带 `enemy_1` 标注）。
- 对照：TRIAL 绿点与红方块的距离 = 当前解的误差。
- 取消勾选 → 红方块消失（Truth 只对调试可见）。

### 步骤 6：提交火控解（验证 System Solution）
- 在完成一次满意的拟合后，点击 **✅ Enter Solution**。
- **预期**：
  - 状态栏显示 `System Solution submitted`。
  - 若当前拟合状态为 `INSUFFICIENT_GEOMETRY` / `MULTIMODAL` / `STALE`，
    会额外提示 LOW confidence（提交但明确告知置信度低）。
  - 海图出现 **SYSTEM 黄色圆圈**（提交的火控解）。
  - 之后新测量不会自动改 SYSTEM 解（需重新 Auto Fit + 再次 Enter）。

### 步骤 7：手动微调 Trial（验证参数编辑）
- 修改 TMA 区任意参数（如 Bearing 或 Speed），观察海图：
  - TRIAL 绿点位置 / 速度箭头随参数实时变化。
- 修改本艇航向/航速，观察：
  - 海图三角、方位盘艏向、状态栏即时更新。
  - S1-02/G-05 命令值/实际值分离：输入航向/航速只写命令值，实际值按最大
    转向率/加速度渐变逼近（状态栏显示 `ACT x° y.ykn → CMD z° (预计 ns)`），
    海图 OWN 三角随实际艏向旋转；到达命令值自动恢复稳态显示。

### 步骤 8：暂停与倍速（验证控制）
- **Pause**：仿真冻结（Time 停止增长），再点恢复。
- **Speed 1x/2x/4x/8x**：Time 增长速度变化，测量产生频率同步变化。

---

## 3. 可玩性闭环

```
声呐方位积累 → Mark 接触 / 自动 S01 → 本艇机动 → Fit TMA
→ 微调 Trial 参数 → Enter Solution（火控解）→ Show Truth 对照误差
```

## 3.5 阶段四：武器与攻击（S1-07 状态：Commit 0-11 + S1-07A UI 已合入，Seeker 重构中）

🚀 Fire 只要有装填管即可点（S1-07 §5.2，无解不是发射许可）；main_ui 按
上下文自动选模式：

```
有 SystemSolution → SOLUTION（预填，保留射程联锁）
无解但有选中接触 → BEARING_ONLY（沿该接触 LOB，无隐藏距离）
都无              → MANUAL（沿本艇艏向，宽搜索扇区）
→ LAUNCHING → WIRE_RUN（PASSIVE_LISTEN 默认 ON / ACTIVE_TX 默认 OFF）
→ 线控命令（course/speed/depth band/active_tx/autonomy/cut_wire，仅 CONNECTED 可收）
→ 导线超长确定性 BROKEN / 玩家 CUT → 拒绝新命令并执行 fallback（§5.5：保持
  最后命令航向 → 预设搜索深度带 → SEARCH → 按预设距离授权自主 + 开主动 TX）
→ 引信按 arm_distance 独立 SAFE→ARMED（与主动/自主解耦）
→ DEAD（燃料耗尽；发射管保持 EMPTY，不自动补装，reload_tube 显式装填）
```

S1-07A 深度 UI：右侧 **Own Ship Maneuver** 面板新增 **Own Depth (m)** 输入与
**▲ Upper / ▼ Lower** 层按钮（只写 commanded_depth_m，实际按 Vz 限速逼近）；
状态行显示 `ACT→CMD 深度 + 换层 ETA + 当前层带`。`stage1_basic_passive.json`
已启用 `depth_layers`（温跃层 120m±10，UPPER/LOWER hold 70/180m）——本艇下潜
跨层后对洋面目标探测 SE/Pd 下降但不断绝（可玩可见）。

信息链：鱼雷 `step(dt, sim_time, TorpedoContext)` **不接收 Truth targets**
（类型级隔离）；UI/事件不含 target_id。深度（S1-07A）：本艇/敌艇/鱼雷
commanded/actual 分离、Vz 限速升降，跨温跃层 TL 只降 Pd 不硬置零。

无头验收：
```bash
godot --headless --path games/sonar --script res://tools/weapon_test.gd   # WEAPON_TEST result=PASS
godot --headless --path games/sonar --script res://tools/weapon_program_test.gd  # WPN-PROG-01..04
godot --headless --path games/sonar --script res://tools/s1_07_state_model_test.gd  # SM1-SM7
godot --headless --path games/sonar --script res://tools/depth_layer_test.gd        # D1-D7
godot --headless --path games/sonar --script res://tools/wire_guidance_test.gd      # WPN-WIRE-01..04
godot --headless --path games/sonar --script res://tools/torpedo_acoustic_test.gd    # WPN-ACOU-01..03
godot --headless --path games/sonar --script res://tools/torpedo_seeker_test.gd      # WPN-SEEK-01/02/04/05
godot --headless --path games/sonar --script res://tools/torpedo_track_test.gd       # WPN-SEEK-06..13
godot --headless --path games/sonar --script res://tools/decoy_test.gd               # CM-01..05 + 谱线分类
godot --headless --path games/sonar --script res://tools/enemy_ai_test.gd            # AI-01..09
godot --headless --path games/sonar --script res://tools/fuze_evidence_test.gd       # FUZE-01..07
godot --headless --path games/sonar --script res://tools/weapon_ui_test.gd           # UIW-01..06
godot --headless --path games/sonar --script res://tools/s107_integrated_test.gd     # INT-A/B/C
godot --headless --path games/sonar --script res://tools/patch_a_test.gd             # PA-01..03
godot --headless --path games/sonar --script res://tools/patch_b_test.gd             # PB-01..07
godot --headless --path games/sonar --script res://tools/patch_c_test.gd             # PC-01..05
```

UI 集成：`scripts/ui/weapon_panel.gd` 自管按钮 / Fire 模式提示 / Tubes 标签 /
鱼雷日志（5 行）；`scripts/ui/own_maneuver_panel.gd` 本艇航向/航速/深度控制。
main_ui 收到 `fire_requested` 后用自身 own 位置执行发射，面板不持有 Truth own。
WireLink（`scripts/weapon/wire_link.gd`）：放线按鱼雷速度累计、超长确定性
BROKEN（首版不用随机断线）、玩家可 CUT_WIRE；断/切后线控命令拒绝并在 UI 说明
原因（In-water console 属 Commit 11，控制 API 本批已完备）。

Commit 5 声学层（§6.1/§6.2/§9.1/§9.2）：`TorpedoAcousticProfile` 把速度模式
映射到速度/续航/运行噪声源级（QUIET 28kn/1800s/112dB < CRUISE 40kn/1200s/
128dB < HIGH 50kn/800s/146dB）+ 主动收发参数 + 出管/动力启动瞬态；
`command_speed_mode` 切模式按续航比等比折算剩余燃料（HIGH 更快烧完）。
`AcousticEmissionBus` 统一声学事件：本艇主动 Ping / 鱼雷出管瞬态 / 动力启动 /
运行噪声（按模式源级周期广播）/ 主动 Ping（按 profile 节拍）都落
`emission_bus.record`；`World.active_emissions`（S1-04C 契约）是总线事件数组的
同一引用，旧读方零改动。事件只带内部 emitter 引用、绝不携带 target_id/Truth；
截获 SE/Pd 与玩家声呐同源（连续概率、非硬门限）。

Commit 6 Seeker 采样（§6.3/§6.4/§6.5）：`TorpedoSensorAdapter`（World 装配、
注入 env/depth_model/RNG + Truth 声源）是武器侧唯一可触 Truth 的边界，向鱼雷
只输出净化 `SeekerReturn`（无 target_id/真实位置/被动无 range）。被动采样与
玩家声呐同源：SE=SL−TL_layer−N_eff(鱼雷航速)+AG−DT，Pd 连续无硬门限、miss 帧
无 return；鱼雷高速自噪抬 N_eff → 被动 SE 降（§6.2）；跨温跃层 SE 降但不硬断
（depth_relation SAME/CROSS/TRANSITION）。主动 Ping 回波按 tau=2R/c 延迟到点
结算、R_meas=c·tau/2+noise（绝不同 tick 瞬时返回）；误报独立生成不绑 target。
鱼雷出管后被动默认 ON、按 1s 周期采样，SeekerReturn 记入 `seeker_returns`（只
记不转——捕获/转向属 Commit 7 SeekerTrack/制导）。

Commit 7/8（SeekerTrack/制导 + 诱饵）：见 DESIGN.md §0.6 同名小节；鱼雷恢复
真实打靶（捕获→ATTACK→TERMINAL→命中），诱饵经同一声学链竞争。

Commit 9 敌方 AI（§9）：场景 `enemy_spawn` 块启用（旧场景零行为变化）——
`EnemySpawnGenerator` 按方位带/三角距离/航向分布/深度带权重抽样出生（独立派生
RNG，确定性；min_separation 校验 + fallback_spawn），出生入 `world.targets`。
`EnemySensorAdapter`（内核边界）消费 Truth 声源 + 声学事件总线，输出净化证据
（noisy bearing/时间/频带/分类假设/置信度，**无 range/位置/target_id**）；
`EnemyTrackManager` 方位航迹质量（命中 α 涨 / 无证据衰减 = 不确定区扩大）；
`EnemyDoctrineController` 状态机 PATROL_PASSIVE→SUSPICIOUS→TRACKING→ATTACKING
→EVADING→REACQUIRE：反应延迟 3..15s（绝不同 tick 反应）、机动/换层/放诱饵按
doctrine 概率、全部走 TruthEntity 命令值接口（限速率）；反击只有可信方位 →
BEARING_ONLY 宽扇区（程序无隐藏距离，绝不指向玩家真实位置）；AI 鱼雷经独立
WeaponSystem+TorpedoContext（seeker 声源 = 本艇+蓝方诱饵），其主动 Ping/航行
噪声同样落事件总线、可被玩家被动链截获（玩家声呐可听到来袭鱼雷）。未探测到
事件时 AI 行为绝不变。

Commit 10 引信与净化反馈（§10）：`FuzeController`（CONTACT/ACOUSTIC/MAGNETIC
简化几何触发半径；解保双保险 warhead_arm_distance + min_time，SAFE 绝不起爆，
与 Seeker/制导彻底分离）+ `EmissionSanitizer`（事件净化：敌方声学事件单程
概率截获 → noisy bearing 告警证据 POSSIBLE_LAUNCH_TRANSIENT/POSSIBLE_TORPEDO/
TORPEDO_ACTIVE_PING/DECOY_DEPLOYED/DETONATION_HEARD；己方武器事件为本艇事实；
战果层级 classify_detonation 只基于证据+玩家航迹方位）。World 引信引擎结算
爆炸：EXPLOSION 事件入总线（双方可截获）+ Truth 伤害（敌 sunk / 本艇
damaged）+ 最近通过距离台账；普通 UI 只见 `world.player_evidence` 净化证据
队列，命中确认（CONFIRMED_KILL）只经 `_debrief_summary()` 调试通道（Debrief）。

Commit 11 武器 UI（§11）：右侧面板新增 **In-Water Weapons**（每枚鱼雷正交状态
+ 线控按钮组，断线后按钮禁用并给原因）、**Countermeasures**（MOBILE/JAMMER
发射 + 库存/冷却/活动数）、**Weapon Alerts**（净化告警流：POSSIBLE_LAUNCH_
TRANSIENT / POSSIBLE_TORPEDO / TORPEDO_ACTIVE_PING / DECOY_DEPLOYED /
DETONATION_HEARD / PROBABLE_HIT / PROBABLE_KILL，含时间/方位/置信度）、海图
左侧 **深度条**（OWN/TK/DCY 实心=实际 空心=命令，形状+文字双编码）。海图叠加：
线导虚线、搜索扇区边界、Seeker FOV、选中航迹不确定方位线——全部来自己方武器
状态/净化摘要，绝不画 Truth 目标。武器日志不再显示任何 target_id。

Commit 12 集成与 CI 门禁（§13/§14.7）：`s107_integrated_test` 三条全 World 链路
——INT-A 完整击杀链（出生→BEARING_ONLY→授权自主→TIME 开主动→捕获/TERMINAL→
引信爆炸→敌 sunk→Debrief→净化证据判 PROBABLE_*）、INT-B 敌方反击链（Doctrine
自行开火→玩家截获发射瞬态告警→声呐听到来袭雷）、INT-C 固定 seed 复现（两次
运行终态逐字段一致）。配套本艇事实（OWN_FACT）证据补 bearing/se（己方武器
状态合法信息）。主门禁 `tools/ci_tests.txt` 共 24 项。

---

## 4. 常见问题

| 现象 | 说明 |
|---|---|
| 状态显示 INSUFFICIENT_GEOMETRY | 单观测腿不可观测，需本艇机动形成第二腿（正常） |
| 状态显示 MULTIMODAL | 多个假设权重接近，看海图备选解虚线，机动后重拟合 |
| 状态显示 STALE | 最新测量已超出 600s 时限（本艇没动也会触发），继续积累数据即可 |
| 状态显示 BOUNDARY_HIT | 解撞到搜索边界，通常是测量太少或几何病态 |
| FIT 标签没有 ±xx m | 协方差仅在单峰且可观测时输出，不可观测时故意不给误差椭圆 |
| 找不到 TMA Course/Speed | 右侧面板需向下滚动（已加 ScrollContainer） |
| 英文显示 | Web 版 Godot 默认字体无中文字形，已全部英文化 |
| 接触一直是 S01 | 单目标场景只有一个接触，属正常 |
| 想重置 | 刷新浏览器页面（场景固定种子，重开会从 0 开始） |

---

## 5. 自动化验证

仓库自带无头测试。**主门禁清单**见 `tools/ci_tests.txt`（S1-00-REQ-06），
本地按 CI 同口径跑（先 `--import` 注册全局类，逐项要求退出码 0）：
```bash
godot --headless --path games/sonar --import
while read -r t; do
  [ -n "$t" ] && [ "${t#\#}" != "$t" ] || continue
  godot --headless --path games/sonar --script "res://tools/${t}.gd" || exit 1
done < games/sonar/tools/ci_tests.txt
```
清单覆盖 23 项：`play_test`（TMA 验收 7 项：两腿精确恢复 / 单腿不可观测 /
0-360 跨越 / 圆弧机动 / 目标机动检测 / STALE 时限 / Truth 隔离）、`stage1_test`、
`stage2_test`、`operator_test`、`dynamics_test`、`towed_test`（A/B 分支消歧）、
`ping_test`、`ping_tma_integration_test`、`weapon_test`、
`s100_integrity_test`（S1-00 信息链完整性验收 D1-D8）、`s1_03b_scope_test`
（S1-03B 阵列作用域 + 拖曳歧义呈现）、`s1_03c_test`（S1-03C 证据组关联 +
阵列中心几何 + coverage/发射扇区接入，C1-C8）、`s1_07_state_model_test`
（S1-07 正交状态模型/WeaponProgram/Truth 隔离，SM1-SM7）、`depth_layer_test`
（S1-07A 双层深度 + 跨层 TL + 场景集成，D1-D7）、`weapon_program_test`
（S1-07 Commit3 发射模式 MANUAL/BEARING_ONLY/SOLUTION + tube EMPTY，
WPN-PROG-01..04）、`wire_guidance_test`（S1-07 Commit4 WireLink 放线/断切/
命令门 + fallback 执行，WPN-WIRE-01..04）、`torpedo_acoustic_test`（S1-07
Commit5 声学画像模式表/燃料折算 + EmissionBus 出管/动力启动/运行噪声/主动
Ping 事件与截获概率，WPN-ACOU-01..03）、`torpedo_seeker_test`（S1-07 Commit6
TorpedoSensorAdapter+SeekerReturn：被动默认 ON 收到 return / 被动无 range 且
净化无 Truth / miss 无 return / 跨层 SE 降 / 高速自噪降被动 SE / 主动 TOF
tau=2R/c 与测距 / 误报独立，WPN-SEEK-01/02/04/05）、`torpedo_track_test`
（S1-07 Commit7 SeekerTrack 航迹/捕获滞回/miss 丢失/重搜不跟 Truth/重捕获/
多目标 score 竞争/净化 API/有限转向率制导 + WIRE_ONLY 不擅自转向 + SEARCH
扇区扫掠，WPN-SEEK-06..13）、`decoy_test`（S1-07 Commit8 诱饵：发射器库存/
冷却/激活延时/寿命、同一声学链竞争拉锁且 Seeker 不读 is_decoy、固定 seed
复现，CM-01..05；含鱼雷谱线随模式 + 谱一致性分类稀释 JAMMER 假峰）、
`enemy_ai_test`（S1-07 Commit9 敌方：出生确定性/合法性、无证据不感知、Ping 与
发射瞬态截获只产 noisy bearing、反应延迟 ∈[3,15]s、BEARING_ONLY 宽扇区反击、
AI 主动 Ping 同样暴露、规避命令值限速率、World 集成，AI-01..09）、`fuze_evidence_test`（S1-07
Commit10 引信：SAFE 双保险不起爆/直航命中爆炸/Truth 伤害/Debrief 台账/战果
层级纯函数/敌方鱼雷命中本艇→净化 DETONATION_HEARD/净化扫描/未命中零台账，
FUZE-01..07）、`weapon_ui_test`（S1-07 Commit11 UI：在水控制台状态正交呈现/
断线禁用拒绝原因/诱饵库存禁用/告警 PROBABLE_KILL 标注且绝无 CONFIRMED 与
target_id/深度条/日志净化，UIW-01..06）、`s107_integrated_test`（S1-07 Commit12
集成：全链击杀 INT-A/敌方反击告警+来袭雷可听 INT-B/固定 seed 复现 INT-C，
无 UI 直读 Truth、证据无 target_id）、`patch_a_test`（评审 Patch A：敌方感知
真方位来自几何 bearing 绝不用深度冒充（深度≠方位刻意组合）/双方鱼雷 ID 前缀
唯一（T01 vs ET01）/敌方在水计数结算释放可再反击，PA-01..03）、`patch_b_test`（评审 Patch B：alpha-beta 滤波恒速收敛+跨界无跳变/
扫描级一对一关联/accept→ASSISTED/authorize 无锁→SEARCH 扫掠/无导线程序自主可达
/WIRE_ONLY 不 ATTACK/主动链 ping_id+FOV 门+NO_RETURN 完成，PB-01..07）、
`patch_c_test`（评审 Patch C：统一声场 UI 路径可探测鱼雷+已探测样本显示下限/
谱线逐线声学净化不复制 Truth/主动回波反射历元一致+timestamp/available_time/
己方声源 OWN token 资格拒绝+引信独立安全保险，PC-01..05）、
`patch_d_test`（评审 Patch D：威胁证据观察点快照+evidence_kind+available_time
LOB 起点不随本艇机动漂移（AT-09）/ThreatTrack 时间-方位-种类升级链关联抑制
告警洪泛/SeekerBeamState 扇区单一真源+适配器被动与主动门边界内外与正后行为
（AT-19）/海图真实 torpedo_id+tx_state 驱动脉冲+真实 ±σ+命中测试与 auto_frame
/证据与 track 无 Truth 泄漏，PD-01..05）、
`patch_e_test`（评审 Patch E：命令拒绝具体原因 WIRE CUT/LAUNCHING/NO
CANDIDATE+五正交状态逐帧行/武器卡重建保留 header+无候选 Accept 禁用+事件
日志一行一事件/s1_combat 场景装配+SONAR_SCENARIO 选择器+UI 同配置端到端
/搜索扫掠自当前航向连续初始化/侧栏宽度契约 300-340-420/候选摘要含
bearing_sigma_deg，PE-01..06）、
`patch_f_test`（评审 Patch F：swept 引信连续碰撞+垂直门（AT-15）/瀑布与
告警封顶后 sequence 驱动持续刷新（AT-14）/s1_combat e2e 反击链无 Truth
泄漏（AT-17 来袭半环），PF-01..03）、
`calibration_envelope_test`（AT-16 声学标定包线：固定 seed MC 被动/主动
P_d(R)，R50/R90 设计区间冻结+次序关系+复现性，CAL-1..9）。

### S1-00 信息链热修状态（2026-09）

- ① detected/evidence_id 证据契约（GAP-DATA-01/03）：miss 永不进玩家链
  （World/UI 三层过滤）；一次物理到达 = 一个 evidence_id，A/B 镜像共享，
  Track 按去重 evidence_id 计数（`evidence_count()` / `detection_count()`）。
- ② 删主动自动旁路（REQ-03）+ TMA robust refit 统一口径（REQ-04，r2 插回
  候选集首位、全候选在 inlier 子集重精化、剔除计罚进 weighted_cost）+
  残差行 schema（REQ-05，`{measurement_id, evidence_id, component, raw_value,
  raw_unit(deg|m), normalized, inlier, timestamp}`，废除 `residual_deg`）。
- ③ CI 主门禁（REQ-06）：deploy.yml 新增 `test` job，按 `tools/ci_tests.txt`
  显式执行全部测试并以非零退出码为准，`export-web` 依赖它。

### play_test 的 TMA 验收细节

`play_test` 输出 `TMA_ACCEPT tN ok` 共 7/7（两腿精确恢复 / 单腿不可观测 /
0-360 跨越 / 圆弧机动 / 目标机动检测 / STALE 时限 / Truth 隔离）。

UI 截图验证（窗口模式，输出 `tools/ui_preview.png`）：
```bash
godot --path games/sonar --script res://tools/ui_snapshot.gd
```
预期 fit 状态 `CONVERGED`、`legs=2`（场景中本艇在 240s 处 +70° 转向）。

CI（GitHub Actions）每次 push 自动跑 lint + 全量测试门禁 + Web 导出。
