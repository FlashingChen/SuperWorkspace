---
name: workspace-tutorial-motion
description: 为工作台的单段口播或录屏视频制作杂志纪录片级 Remotion AI 包装（强制前置资料查证与真实官方品牌 SVG 拉取 + 实体纸卡/哑光信息图 + 实拍为主的轻量证据层 + 3D 世界相机与视觉隐喻）；严格保护电脑演示及原时长、声音。
---

# AI 包装总纲

本技能是应用随包版本。只读取本目录规则与 `references/`，不加载本机其他同类技能；只在当前素材工作目录读写工程与产物。

## 1. 宿主不可违背的底线

- 只完成当前单段视频的 AI 包装；**不自动拼装整片、不变速、不重编或混入音频/BGM/音效、不烧录字幕、不做封面**（原片音画与字幕均由宿主统一管理）。
- 严格保留原片分辨率、帧率、时长、时间关系与完整音轨；原有缩放与点击动效属于原片，不删除、不重复施加。
- 简报已给出画面分区、关键帧、字幕或现成工程时直接使用，不重复抽帧、OCR、语音识别或手写独立抠像脚本，也不写长篇分析文档。

## 2. 强制前置阶段：查证与真实资产拉取（写 TSX 前必须完成）

**禁止跳过本阶段直接写 React 代码！** 动笔前必须先扫描口播字幕与简报，完成以下两件事：

### 2.1 真实品牌 Logo 拉取（绝对禁止手绘品牌 Logo）

- 凡口播提到任何真实公司、平台、软件或 AI 模型（如 Google、OpenAI、Anthropic、Claude、Gemini、Meta、SpaceX、GitHub、Apple、Figma、DeepSeek、Qwen、Doubao 等），**严禁自己手写 `<svg>` 凭空画 Logo 或用字母圆圈敷衍**。
- 必须先用命令行下载真实官方 SVG 到 `public/assets/logos/<slug>.svg`：
  1. **AI 模型与科技大厂优先**（支持彩色与单色官方标）：
     `curl -fsSL --create-dirs "https://raw.githubusercontent.com/lobehub/lobe-icons/master/packages/static-svg/icons/<slug>.svg" -o public/assets/logos/<slug>.svg`
     常用 slug：`openai`、`anthropic`、`claude-color`、`gemini-color`、`google-color`、`meta-color`、`grok`、`deepseek-color`、`qwen-color`、`doubao-color`、`minimax-color`、`kimi-color`、`perplexity-color`、`cursor`、`github`、`vercel` 等。
  2. **通用开源/科技品牌备选**：
     `curl -fsSL --create-dirs "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/<slug>.svg" -o public/assets/logos/<slug>.svg`
  3. **下载后必须校验**：确认文件非空且包含 `<svg`；组件内通过 `<Img src={staticFile('assets/logos/<slug>.svg')} />` 或 `BrandDeckCard` / `EditorialRankCard` 的 `logoSrc` 渲染。
  4. **兜底铁律**：如果某个小众品牌确实无法拉到官方 SVG，**只允许使用纯排版文字标（如 `BrandDeckCard` 不传 `logoSrc`）**，绝对禁止手绘山寨图形。

### 2.2 一手事实与数据查证（绝对禁止编造）

- 口播提到具体公司、模型、跑分/榜单、营收/用户规模、价格、版本号、官方表态或关键事件时，必须先主动联网检索核实，并将查到的**精确数值、日期、出处与原文引语**整理保存到工作目录 `research-facts.json`（简短 JSON，不写长文）。
- 画面展示的每一条数据或原文引语，必须带等宽全大写溯源标注（如 `ARTIFICIAL ANALYSIS · NOV 22`、`OFFICIAL PRICING`、`ALPHABET Q3 EARNINGS`）。
- 确实没有可查证客观数值时，**绝不杜撰假分数（如假 `96 pts`）**，改用定性判断、真实引语或视觉隐喻。

## 3. 杂志纪录片级视觉哲学（拒绝廉价 AI 模板）

1. **去“廉价霓虹毛玻璃”，用“实体纸卡与哑光杂志风”**
   - 详见 [references/talking-head-style.md](references/talking-head-style.md)。拒绝满屏发光青/红/金毛玻璃大胶囊。
   - 优先使用高对比实体载体：纯白品牌卡（`BrandDeckCard`）、哑光猩红/炭黑/纸质主题卡（`EditorialRankCard`）、极细 1px 分割线数据条（`DataRuleList`）、纸面高亮引语卡（`QuoteEvidenceCard`）、二维定位坐标系（`QuadrantPlot`）。**绝对禁止 Emoji**。
2. **以真人实拍为主（60%–70% 实拍 : 30%–40% 全屏暗色舞台）**
   - 大部分时间保留真实房间实拍画面，在人物左右两侧以透明 `overlays` 轻量叠放红/黑榜卡、极简细线数据条、肩后左右分列大字（`matte: "behindPerson"`），**不要动不动把整个房间抹黑切进空洞的全屏舞台**。
   - 只有讲到真正需要空间叙事的概念（品牌牌阵摊开、厂商生态版图、二维象限图、物理隐喻动画、真实录屏放大）时，才切进全屏暗色舞台（`shots` + `<StageFrame>` + 3D `<WorldCamera>`）。
3. **真正的视觉隐喻，而不是把口播句子搬上卡片**
   - 讲到稀释、瓶颈、定位夹缝、反差、递进时，优先画**二维坐标系、趋势曲线、物理隐喻图解或真实文本荧光笔批注**，让观众 0.5 秒直觉看懂，而不是读 3 张并排文字卡。

## 4. 分区权限与素材语言规则

- **`screenDemo`（纯录屏演示）**：完整保留原画面，严禁推拉、裁切、重排、覆盖电脑内容或声明 `matte`；无安全空白就不加动效。
- **`mixed`（人物与演示共存）**：仅在简报给出的无人物安全侧做裁切后的局部透明叠层（`overlays`），不得移动或放大整个录屏。
- **`aRoll`（全屏口播）**：灵活组合透明实拍叠层（`overlays`，可选 `matte: "behindPerson"`）与高密度全屏 3D 分幕（`shots`，可选 `matte: "personForeground"`）。
- **画面语言与素材库**：中文口播一律用简体中文（保留英文专有名词），全英文口播全用英文；`public/library/` 通过 `staticFile('library/...')` 直引，简报标明**「必须使用」**的素材必须完整呈现。

## 5. 宿主交付闭环

1. 登记全部分幕与透明叠层到 `motion-manifest.json`。
2. 预检：`node sw-motion.mjs inspect`（定向微调加 `--shots <id>`），检查 Contact Sheet（确认无遮挡、无黑边、无自绘假 Logo、无假数字、无 Emoji、无廉价霓虹泛滥），控制在 1–2 轮内。
3. 交付：`node sw-motion.mjs render`（自动复用 `.sw-cache/`、按需调用原生 Apple Vision 抠像并自动施加两段式无重影人物缩放/滑行转场、硬件编码合成 `motion-pending.mp4`），返回 `ok: true` 后直接汇报交付，不手写合成脚本。

## 6. 按需查阅

- `motion-manifest.json`、`matte` 参数与 `src/sw-kit` 实体组件速查 → [references/host-adapter.md](references/host-adapter.md)
- 全屏口播美学基因、实体材质规范与实拍配比 → [references/talking-head-style.md](references/talking-head-style.md)
- `screenDemo` / `mixed` 录屏零入侵边界与安全侧叠层 → [references/screen-demo-rules.md](references/screen-demo-rules.md)
- 3D 世界相机编排与跨章节回指示例 → [references/motion-recipes.md](references/motion-recipes.md) 与 [references/chapter-connection.tsx](references/chapter-connection.tsx)
