# shared/assets — 仓库级共享素材库

与 `shared/addons/game_kit`（代码）同哲学：**素材入库一次，多游戏通过"风格契约"复用**。
AI 生成的素材（或人工绘制/购买的）经本目录入库，游戏侧声明契约后由同步脚本/CI 自动注入。

> **双层资产**：本目录是**共享层**（跨游戏复用）。某个游戏独有素材放
> `games/<名>/assets/images/`（**游戏专用层**，正常提交），同名时游戏层覆盖共享层。

## 目录结构

```
shared/assets/
  styles/<style-id>/          # 风格契约库：每种美术风格一个目录
    contract.yaml             # 契约：风格描述 + prompt 模板 + 生成参数
    anchor.png                # 风格锚点图（该风格的代表性成品，作图生图参考）
    _drafts/                  # 生成中的草稿（各渠道产出先丢这，筛选后入库，可不提交）
  images/<style-id>/<类别>/   # 共享素材（按风格 + 类别组织）
    characters/ items/ bg/ ui/ effects/
  audio/<类别>/               # 共享音频（bgm/ / sfx/ / ambient/）
```

## 生图渠道（渠道无关）

- **ImageGen**（WorkBuddy 内置）：对话内调用，文生图/图生图
- **Codex CLI**（本机）：`codex exec` 生成，产物丢 `_drafts/` 后统一入库
- 其他模型：同一规格（PNG + 命名规范）即可接入
- 雪碧图：AI 直出后必须过 `tools/check_sprite_sheet.py` 校验门禁，不合格输出返工清单

## 游戏怎么用（风格契约机制）

游戏在 `project.godot` 里声明要用的风格与音频包：

```ini
[game_kit]
asset_style="flat-cartoon"      # 注入 shared/assets/styles/flat-cartoon/ 的素材
audio_packs=""                  # 可选：逗号分隔，注入 shared/assets/audio/<pack>/
```

运行时素材路径：`res://assets/_shared/<类别>/<文件名>.png`。
`assets/_shared/` 是**注入物**（`games/*/assets/_shared/` 已在 .gitignore），本地跑
`bash tools/sync_shared.sh` 生成，CI 构建时也会注入同样内容。游戏专用素材放
`games/<名>/assets/images/`，同名时优先。

**复用收益**：改一张共享素材（如 `styles/flat-cartoon/items/grapes.png`）→ 所有声明
`asset_style="flat-cartoon"` 的游戏同步更新，无需改游戏代码。

## 新增一种风格

1. `mkdir shared/assets/styles/<style-id>`
2. 写 `contract.yaml`（见下），放一张 `anchor.png` 锚点图
3. 给目标游戏的 `project.godot` 加 `[game_kit] asset_style="<style-id>"`
4. 跑 `bash tools/sync_shared.sh` 注入，游戏里用 `res://assets/_shared/...` 引用

## contract.yaml 格式

```yaml
id: flat-cartoon            # 与目录同名
name: 扁平卡通风
description: >-
  类似割绳子/愤怒小鸟的扁平矢量卡通风。粗描边、高饱和纯色、
  无渐变滥用、无写实材质。适合休闲合成类游戏。
anchor: anchor.png          # 锚点图路径（相对本目录）
prompt_template: >-
  扁平卡通风游戏素材，{subject}，居中构图，粗黑色描边，
  高饱和纯色填充，简单几何形状，纯白背景，无文字无阴影，矢量风
image_params:               # 生图默认参数
  size: 1024x1024
  quality: high
  background: transparent
categories: [characters, items, bg, ui, effects]   # 该风格覆盖的素材类别
```

## AI 生成规范（为什么这么做）

- **锚点先行**：同一套素材的所有图都用 `anchor.png` 做图生图参考（image1 + 高
  input_fidelity），prompt 里只换 `{subject}`，保证观感统一——这是对抗"AI 风格漂移"
  的核心手段。
- **透明底**：角色/道具/特效一律透明底 PNG（渠道直出不透明时用
  `tools/postprocess_image.py` 去白成透明）；背景图用不透明。
- **每素材 2-3 张候选**：人工挑 1 张满意的入库，其余丢弃（不要全进仓库）。
- **雪碧图走校验门禁**：`tools/check_sprite_sheet.py` 校验网格/透明/空帧/贴边/居中，
  不合格输出返工清单贴回生成方（详见 docs/asset_pipeline.md 第七节）。
- **体积红线**：单张 ≤ 512 KB；1024px 起步、游戏内按需缩放；入库前用工具压一遍
  （调色板量化，postprocess_image.py 内置）；CI 会检查。
- **命名**：snake_case 语义化（`grapes.png`、`space_ship.png`），禁止 `img_001.png`。

## 音频库

程序化音效已由 `GameKitSfx`（shared/addons/game_kit/sfx.gd）覆盖，本目录的 audio/
用于**素材型音频**：BGM、环境音、语音等无法程序化合成的内容。入库规范：
`shared/assets/audio/<类别>/<语义名>.ogg`（优先 ogg 压缩格式），游戏按 `audio_packs`
声明注入后以 `res://assets/_shared/audio/...` 引用。

## 详细流程

完整管线（风格锚点 → 多渠道生成 → 雪碧图校验/后处理 → 导入测试 → 体积门禁）见
[../docs/asset_pipeline.md](../docs/asset_pipeline.md)。
