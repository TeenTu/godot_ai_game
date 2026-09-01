# AI 素材生成管线规范（docs/asset_pipeline.md）

用生图模型为游戏生成美术素材的完整流程规范。目标：**风格统一、可复用、体积可控、渠道无关**。

```
定风格锚点 → 多渠道生成 → 雪碧图校验/后处理 → 导入测试 → 体积门禁
     ↑_____________________________________________|
               不合格 / 风格漂移 → 返工清单回炉
```

## 一、生图渠道（渠道无关，统一产出规格）

本仓库不绑定单一生图模型——**ImageGen、本机 Codex CLI、未来其他模型都是"生产者"**。
无论哪个渠道出图，都遵循同一规格：

| 渠道 | 怎么用 | 说明 |
|---|---|---|
| **ImageGen**（WorkBuddy 内置，腾讯混元） | 对话内直接调用 | 文生图 / 图生图（`image1` 锚点 + `input_fidelity`）/ 支持 `background`、`size`、`quality` 参数 |
| **Codex CLI**（本机） | 终端跑 `codex exec "..."` | 产出物丢进 `shared/assets/styles/<id>/_drafts/` 或游戏专用目录，走同一套后处理 |
| 未来其他模型 | 同一规格接入 | 只要是"PNG + 规格说明"即可入库 |

**统一产出规格**：
- 单帧素材：透明底 PNG（若渠道不直出透明，用 `tools/postprocess_image.py` 去白成透明）
- 雪碧图：**AI 直接出整张图集**（Codex 等有能力），但必须过 `tools/check_sprite_sheet.py` 校验门禁
- 命名：snake_case 语义化；尺寸 1024 起步不超 1536；quality=high

⚠️ ImageGen 每次生成消耗约 5-10 credits；Codex CLI 走本机资源。批量前确认预算。

## 二、风格契约（每个游戏一个）

风格契约定义在 `shared/assets/styles/<id>/contract.yaml`，游戏用 `project.godot`
的 `[game_kit] asset_style="<id>"` 声明引用。契约字段：

- `description` — 风格一句话定义（写清楚"要什么、不要什么"）
- `anchor` — 锚点图，该风格的代表成品
- `prompt_template` — 生成 prompt 的骨架，`{subject}` 占位，**所有素材共用**，
  只换主体词 → 观感统一
- `image_params` — 默认生图参数（size/quality/background）
- `categories` — 该风格覆盖哪些素材类别

**风格契约是"游戏项目的艺术约定"**：换风格 = 换契约 + 重新注入，游戏代码零改动。

## 三、prompt 模板写法

好的模板 = 风格词（固定） + 主体词（变化） + 负面约束：

```
[风格词，来自 contract.description] 的 {subject}，[构图：居中/侧视图]，[风格细节：
粗描边、纯色填充、无文字无阴影]，透明背景 PNG
```

示例（flat-cartoon 风格生成葡萄）：
> 扁平卡通风游戏素材，一串紫葡萄，居中构图，粗黑色描边，高饱和纯色填充，
> 简单几何形状，透明背景，无文字无阴影，矢量风

## 四、素材分级：什么该 AI 生成

| 适合 AI 生成 | 不建议 AI（继续程序化） |
|---|---|
| 角色 / 敌人 / NPC | 特效帧（爆炸/光效）——程序化更流畅省体积 |
| 道具 / 拾取物 / 水果 | 像素画——AI 像素风不稳定，后期处理成本高 |
| 背景 / 场景插画 | UI 九宫格边框——规则图形手写更好 |
| 图标 / 横幅 / 封面图 | 严格关键帧对齐的动画序列（帧间距依赖物理计算的） |

## 五、双层资产：共享 vs 游戏专用

素材分两层，**分层共存、游戏层覆盖共享层**（不是二选一）：

| 层 | 路径 | 放什么 | 规则 |
|---|---|---|---|
| **共享层** | `shared/assets/` | 可跨游戏复用（风格化水果、通用图标、通用背景） | 入库一次、契约引用、改一处全仓生效 |
| **游戏层** | `games/<名>/assets/images/` | 该游戏独有（专属主角、剧情道具、特定场景） | 游戏私有、正常提交 |

- 决策规则一句话：**"别的游戏可能用 → 共享；只属于这个游戏 → 专用"**
- 覆盖规则：游戏层同名文件优先于注入的 `_shared/`（注入只写 `assets/_shared/`，
  永不覆盖游戏本地目录）——所以共享更新不会冲掉游戏的定制版本
- 图集等整组素材同理：通用动画进共享、专属角色动画进游戏层

## 六、入库与命名

```
shared/assets/styles/<id>/{contract.yaml, anchor.png}
shared/assets/images/<id>/<类别>/<snake_case名>.png
games/<name>/assets/images/<类别>/<snake_case名>.png   ← 游戏专用层（正常提交）
games/<name>/assets/_shared/...                         ← 注入物，gitignore，不提交
```

- 命名：`snake_case` 语义化（`grapes.png` / `space_ship.png`），禁 `img_001.png`
- 类别：`characters/ items/ bg/ ui/ effects/`
- **每素材 2-3 张候选，人工挑 1 张**，其余不入库（控制仓库膨胀）
- 素材入库后跑 `bash tools/sync_shared.sh` 注入到各游戏验证

## 七、雪碧图：AI 直出 + 校验返工循环

**AI（尤其 Codex 这类具备推理能力的）可以直出合格雪碧图**——所以脚本不负责"拼图集"，
而是做**质量门禁**：`tools/check_sprite_sheet.py` 校验，不合格输出结构化返工清单。

```
AI 生成雪碧图 → check_sprite_sheet.py 校验 → 全部通过 → 入库
                        ↓ 有问题
              输出返工清单（哪帧、什么问题、怎么改）
                        ↓ 贴回生成方
                   AI 按清单重画 → 再校验（循环）
```

校验项（`--frame WxH` 必传）：
1. **网格完整**：图片尺寸是帧大小的整数倍
2. **透明背景**：图集四角无杂色
3. **空帧**：格子内内容占比 < `--min-fill`（默认 2%）
4. **贴边/越界**：内容距格子边缘 ≤ `--edge-tol`（默认 2px），防邻帧粘连
5. **居中偏移**：内容中心偏离格子中心 > `--center-tol`（默认 35%）
6. **相邻粘连**：共享边界两侧都有内容 = 溢出

用法示例：
```bash
python tools/check_sprite_sheet.py sheet.png --frame 64x64 --columns 8 --rows 4
# ✅ 通过 → exit 0；❌ 问题清单 → exit 1（清单可直接当 prompt 贴回 Codex）
```

## 八、后处理（生成后、入库前）

1. **透明检查**：`tools/check_sprite_sheet.py` / PIL 检查 alpha 通道
2. **去白成透明**（渠道没直出透明时）：`tools/postprocess_image.py <in> <out>`
3. **裁剪**：裁掉多余留白（PIL `getbbox`）
4. **压缩**：调色板量化到 256 色（卡通风格无损观感）——`postprocess_image.py` 已内置
5. **体积记录**：单张 ≤ 512 KB，超了降分辨率或压缩

## 九、导入 Godot 的设置

- 像素/卡通贴图：**Filter=Nearest**（避免模糊）；插画背景：Linear + mipmap
- 动画帧：用 SpriteFrames 资源导入（帧大小 = 校验时的 `--frame`）
- `.import` 文件由 Godot 生成并提交（与其他素材一致）
- 程序化绘制 vs 贴图：**能混合就混合**——suika 的合成物理（圆形碰撞）不变，
  只把 `_draw()` 换成贴图 Sprite，物理半径照旧

## 十、CI 体积门禁（建议加到 deploy.yml lint job）

```bash
# 检查共享素材与游戏素材体积，超过红线让 CI 红
find shared/assets games/*/assets/images -name "*.png" -size +512k | grep . \
  && { echo "asset too large (>512KB)"; exit 1; } || true
# 有雪碧图的仓库可加：check_sprite_sheet.py 批量门禁（按各图集 --frame 规格）
```

入库素材走 CI 全量构建自动部署（`assets/_shared` 由 CI 注入），
改素材 → push → 全仓更新，无需改游戏代码。

## 十一、音频（素材型）

- 程序化音效 → `GameKitSfx`（已有）；BGM/环境音/语音 → `shared/assets/audio/<类别>/`
- 格式：`.ogg`（体积小，Godot Web 原生支持）
- 游戏 `project.godot` 的 `[game_kit] audio_packs` 声明后注入，`res://assets/_shared/audio/...` 引用
