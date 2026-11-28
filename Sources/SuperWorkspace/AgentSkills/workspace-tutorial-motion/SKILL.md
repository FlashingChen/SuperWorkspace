---
name: workspace-tutorial-motion
description: 为工作台的单段口播或录屏视频制作高质感 Remotion AI 包装（第一性原理视觉叙事 + 3D 世界相机 + 按需 Apple Vision 抠像 + 液态玻璃 HUD + 真实素材与事实查证）；严格保护电脑演示及原时长、声音。
---

# AI 包装总纲

本技能是应用随包版本。只读取本目录规则与 `references/`，不加载本机其他同类技能；只在当前素材工作目录读写工程与产物。

## 1. 宿主不可违背的底线

- 只完成当前单段视频的 AI 包装；**不自动拼装整片、不变速、不重编或混入音频/BGM/音效、不烧录字幕、不做封面**（原片音画与字幕均由宿主统一管理）。
- 严格保留原片分辨率、帧率、时长、时间关系与完整音轨；原有缩放与点击动效属于原片，不删除、不重复施加。
- 简报已给出画面分区、关键帧、字幕或现成工程时直接使用，不重复抽帧、OCR、语音识别或手写独立抠像脚本，也不写长篇分析文档。

## 2. 第一性原理创作哲学（绝不套模板）

1. **视觉基因统一，表现形式完全自由**
   - 锁定底层美学基因（详见 [references/talking-head-style.md](references/talking-head-style.md)）：深炭黑摄影棚舞台、液态玻璃（Liquid Glass）质感 HUD、3D 世界相机与三层视差、克制语义配色、**绝对禁止 Emoji**。
   - 严禁把“遇到什么内容就用什么组件”写死。面对每一句口播先问：**“观众看这一帧画面，怎么才能在 0.5 秒内直觉感受到这句话的画面感或冲击力，而不是靠读字？”**
   - 按语义自由挑选载体（实体剪影、空间尺度隐喻、真实软件/网页界面、数据矩阵、架构连线、元素卡等），拒绝“万物皆套圆角卡片”的网页后台风。

2. **真实至上与主动查证（铁律）**
   - **真实品牌资产优先**：口播提到真实平台、公司或产品时，优先使用真实官方 SVG Logo 或极简 1.5–2px 线性矢量图标（`VectorIcon`），禁用 Emoji 或简陋占位符号。
   - **真实网页与界面优先**：讲到官网、下载页、定价页或软件界面时，优先使用 `public/library/` 真实录屏/截图（用 `MacWindowStage` 承托）；无现成素材时，先调用 `web_search` / `fetch_content` 查清真实域名、文案与界面结构，再用代码高保真还原，严禁编造假域名或抽象横线假线框。
   - **严禁编造假数字**：口播出现笼统榜单、分数、价格或版本说法时，主动联网查证精确数值与出处，并用 `MonoFootnote` 标明来源；若确实没有客观可查数值，绝不杜撰假分数（如假 `96 pts`），改用定性状态（如 `充裕` / `告急` / `第一梯队`）。

3. **真人 A-Roll 为主、人物全程在场、3D 世界相机**
   - 主线永远是“真人在讲”。`aRoll` 口播视频必须保留约 **25%–35% 真实原片 A-Roll**（纯真人开场 → 透明 `behindPerson` 人后大字 → 每 12–18 秒及片尾 3–4 秒平滑回到真实实拍喘息或侧边轻量 HUD），严禁全程黑底盖死。
   - 暗色舞台全屏分幕必须使用 `<StageFrame>` + **3D `<WorldCamera>`**（推进/拉回/摇镜/3D 倾角 + 云台微呼吸），配合 `springIn` / `springMorph` 弹性物理与同幕元素重排，每 2–4 秒推进一次视觉焦点，彻底告别静态 PPT。

## 3. 分区权限与素材语言规则

- **`screenDemo`（纯录屏演示）**：完整保留原画面，严禁推拉、裁切、重排、覆盖电脑内容或声明 `matte`；无安全空白就不加动效。
- **`mixed`（人物与演示共存）**：仅在简报给出的无人物安全侧做裁切后的局部透明叠层（`overlays`），不得移动或放大整个录屏。
- **`aRoll`（全屏口播）**：允许全屏 3D 分幕（`shots`）、透明人后叠层（`matte: "behindPerson"`）与小比例人物前景登台（`matte: "personForeground"`），优先组织为 **2–4 个连续长分幕（每幕 7–15 秒）**。
- **画面语言与素材库**：中文口播一律用简体中文（保留英文专有名词），全英文口播全用英文；`public/library/` 通过 `staticFile('library/...')` 直引，简报标明**「必须使用」**的素材必须完整呈现。

## 4. 宿主交付闭环

1. 登记全部分幕与透明叠层到 `motion-manifest.json`。
2. 预检：`node sw-motion.mjs inspect`（定向微调加 `--shots <id>`），检查 Contact Sheet（确认无遮挡、无黑边、无假数字、无 Emoji、3D 推进不裁切核心元素），控制在 1–2 轮内。
3. 交付：`node sw-motion.mjs render`（自动复用 `.sw-cache/`、按需调用原生 Apple Vision 抠像并自动施加两段式无重影人物缩放/滑行转场、硬件编码合成 `motion-pending.mp4`），返回 `ok: true` 后直接汇报交付，不手写合成脚本。

## 5. 按需查阅

- `motion-manifest.json`、`matte` 参数与 `src/sw-kit` 组件速查 → [references/host-adapter.md](references/host-adapter.md)
- 全屏口播美学基因、液态玻璃规范、构图节奏与景别适配 → [references/talking-head-style.md](references/talking-head-style.md)
- `screenDemo` / `mixed` 录屏零入侵边界与安全侧叠层 → [references/screen-demo-rules.md](references/screen-demo-rules.md)
- 3D 世界相机编排与跨章节回指示例 → [references/motion-recipes.md](references/motion-recipes.md) 与 [references/chapter-connection.tsx](references/chapter-connection.tsx)
