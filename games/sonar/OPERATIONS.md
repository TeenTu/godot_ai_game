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
- 注意：main_ui 默认 `world.auto_measurements = false`；旧冒烟/回归工具
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

### 步骤 8：暂停与倍速（验证控制）
- **Pause**：仿真冻结（Time 停止增长），再点恢复。
- **Speed 1x/2x/4x/8x**：Time 增长速度变化，测量产生频率同步变化。

---

## 3. 可玩性闭环

```
声呐方位积累 → Mark 接触 / 自动 S01 → 本艇机动 → Fit TMA
→ 微调 Trial 参数 → Enter Solution（火控解）→ Show Truth 对照误差
```

## 3.5 阶段四：武器与攻击

提交 System Solution 后 🚀 Fire 按钮亮起。鱼雷自决策（不读玩家位置/Truth）：

```
Fire（仅读 SystemSolution）→ 直航 → 安全距离后 seeker ENABLED
→ 蛇形 SEARCH → 主动声自导 ACQUIRE（变橙色）
→ PURSUIT 追踪 → 命中（damage_state=sunk，紫色环消失）
```

无头验收：
```bash
godot --headless --path games/sonar --script res://tools/weapon_test.gd
# 看到 WEAPON_TEST result=PASS
```

UI 集成：`scripts/ui/weapon_panel.gd` 自管按钮 / Tubes 标签 / 鱼雷日志（5 行），main_ui
收到 `fire_requested` 后用自身 own 位置执行发射，武器面板不持有 Truth own。

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

仓库自带无头测试，本地跑：
```bash
godot --headless --path games/sonar --script res://tools/stage1_test.gd
godot --headless --path games/sonar --script res://tools/stage2_test.gd
godot --headless --path games/sonar --script res://tools/play_test.gd
```
均需输出 `PASS`。其中 play_test 包含 TMA 自动拟合验收测试 7 项
（两腿精确恢复 / 单腿不可观测 / 0-360 跨越 / 圆弧机动 / 目标机动检测 /
STALE 时限 / Truth 隔离），输出 `TMA_ACCEPT tN ok` 共 7/7。

UI 截图验证（窗口模式，输出 `tools/ui_preview.png`）：
```bash
godot --path games/sonar --script res://tools/ui_snapshot.gd
```
预期 fit 状态 `CONVERGED`、`legs=2`（场景中本艇在 240s 处 +70° 转向）。

CI（GitHub Actions）每次 push 自动跑 lint + 冒烟 + Web 导出。
