# Sonar 操作验证手册（Stage 1-3）

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
│          │  - 接触 LOB 线（彩色射线）      │  - Show Truth      │
│          │  - TMA 轨迹（橙红折线）        │  - 状态栏/接触列表   │
│          │  - TRIAL 绿点+速度箭头        │  - 本艇机动区       │
│          │  - SYSTEM 黄圈                │  - TMA 解算区       │
│          │  - Truth 红方块（调试）        │  - Dot Stack       │
└──────────┴──────────────────────────────┴───────────────────┘
```

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

### 步骤 3：拟合 TMA（核心验证）
- 点击右侧 **🔄 Fit TMA** 按钮（可能需要向下滚动面板）。
- **预期**：
  - 状态栏出现 `TMA ✓ B..° R..m C..° S..kn RMS..°`。
  - TMA 解算区的 Bearing/Range/Course/Speed 四个输入框被自动填充。
  - 海图出现 **TRIAL 绿色圆点 + 速度向量箭头**，以及橙红色 TMA 预测轨迹折线。
  - Dot Stack 显示 `RMS x.xx° (N pts)`。

> ⚠️ 注意（预期行为，非 bug）：
> 本艇不机动时，纯方位 TMA 存在「近慢/远快」歧义——拟合出的距离/航速
> 可能明显偏离真值（例如 R 只有几百米而真值几千米）。这是需求文档明确
> 描述的 TMA 病态特性，需要本艇机动才能收窄。打开 Show Truth 可对照。

### 步骤 4：本艇机动（验证歧义收窄能力）
- 在 **Own Ship Maneuver** 区点击「Right 5°」数次（或直接改 Own Course），
  再点「+2kn」一两次。
- 继续跑 30~60 秒，让新测量积累。
- 再次点击 **Fit TMA**。
- **预期**：
  - 海图 OWN 三角和轨迹明显转向/弯折。
  - 方位盘艏向（蓝色粗线）随航向改变。
  - 第二次拟合的解可能变化（不保证必然收敛，但这是玩法核心：多次机动 + 观测）。

### 步骤 5：Show Truth 调试（验证 Truth 隔离）
- 勾选 **Show Truth (debug)**。
- **预期**：海图出现 **红色方块**（真实目标位置，带 `enemy_1` 标注）。
- 对照：TRIAL 绿点与红方块的距离 = 当前解的误差。
- 取消勾选 → 红方块消失（Truth 只对调试可见）。

### 步骤 6：提交火控解（验证 System Solution）
- 在完成一次满意的拟合后，点击 **✅ Enter Solution**。
- **预期**：
  - 状态栏显示 `System Solution submitted`。
  - 海图出现 **SYSTEM 黄色圆圈**（提交的火控解）。
  - 之后新测量不会自动改 SYSTEM 解（需重新拟合 + 再次 Enter）。

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

---

## 4. 常见问题

| 现象 | 说明 |
|---|---|
| TMA 距离/航速看起来"不对" | 纯方位 TMA 病态歧义，需机动 + 多观测腿（需求文档验收标准） |
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
均需输出 `PASS`。CI（GitHub Actions）每次 push 自动跑 lint + 冒烟 + Web 导出。
