# 宿主适配器与组件速查（`sw-motion.mjs` & `src/sw-kit`）

工作目录已自动注入 `sw-motion.mjs`（宿主渲染适配器）与 `src/sw-kit/`（共享 3D 相机与液态玻璃组件库）。

## `motion-manifest.json` 结构

```json
{
  "version": 1,
  "fps": 60,
  "width": 3024,
  "height": 1702,
  "shots": [
    {
      "id": "Act1",
      "composition": "Act1",
      "start": 4.4,
      "end": 18.8,
      "files": ["src/acts/Act1.tsx"],
      "matte": "personForeground",
      "personScale": 0.44,
      "personAnchor": "bottomRight"
    }
  ],
  "overlays": [
    {
      "id": "HeroTitle",
      "composition": "HeroTitle",
      "start": 1.6,
      "end": 4.4,
      "x": 0,
      "y": 0,
      "width": 3024,
      "height": 1702,
      "files": ["src/overlays/HeroTitle.tsx"],
      "matte": "behindPerson"
    }
  ]
}
```

### 按需本地人物抠像（`matte`）与自动无重影转场

仅在 `aRoll` 镜头上按需声明，无需手写抠像脚本。`sw-motion.mjs render` 会调用 macOS 原生 Apple Vision 仅对该时间段生成蒙版并缓存：

- `"matte": "behindPerson"`（人后压字 / 背景叠层）：原片在底 → 透明叠层在中 → 抠出的人物前景压回最上层，标题自然穿行在人物肩后。
- `"matte": "personForeground"`（人物无框登台）：暗色 3D 舞台在底 → 抠出的人物前景叠在最上层并自动轻微羽化边缘，且宿主内置 **两段式无重影平滑转场**：
  - 从真实 A-Roll 进入时：先在人物原位（`1.0`）背后柔和淡入暗色舞台，再将人物丝滑缩小滑向目标站位，彻底消除双头重影；
  - 相邻 `personForeground` 分幕间：人物直接平滑滑行到下一站位（如 `bottomRight` → `bottomCenter`）；
  - 退出回真实 A-Roll 时：人物先丝滑放大回原位（`1.0`），再柔和淡出舞台露出真实房间。
  - 可选参数：`personScale`（`0.15–1.0`，紧凑讲解推荐 `0.40–0.45`）、`personAnchor`（`"bottomRight"` 默认 / `"bottomCenter"` 双栏对比居中支点 / `"bottomLeft"` / `"topRight"`），或显式像素坐标 `personX`、`personY`。

## `src/sw-kit` 导出速查

直接 `import { BrandDeckCard, EditorialRankCard, DataRuleList, QuoteEvidenceCard, QuadrantPlot, WorldCamera, StageFrame, SpokenMicroPill, VectorIcon, CornerBadge, MonoFootnote, LiquidMeter, TopStepperBar, MacWindowStage, MediaCard, PhoneMockup, defaultTheme, SAFE_ZONES, springIn, springMorph, ease, pop, stagger } from '../sw-kit'`：

| 导出 | 职责与要点 |
| :--- | :--- |
| `<BrandDeckCard>` | **主力品牌实体卡**：纯白卡片 + 真实官方 SVG Logo（`logoSrc="assets/logos/..."`，严禁手绘 Logo）+ 底部极简分类标签，适合品牌牌阵、产品罗列与对比。 |
| `<EditorialRankCard>` | **主力侧边/结论卡**：哑光猩红（`crimson`）/ 炭黑（`obsidian`）/ 纸面（`paper`）实体卡，带小 Logo、红黑榜徽章、要点列表与等宽溯源，零廉价霓虹发光。 |
| `<DataRuleList>` | **杂志风细线数据条**：`1px` 分割线 + `3px` 弹簧进度条 + 等宽右对齐数字 + 底部大写等宽真实出处（`source` 必填）。 |
| `<QuoteEvidenceCard>` | **真实引语/文档批注卡**：暖白纸面底，支持荧光黄高亮句（`highlight: true`）与右侧红色批注标签，适合展示查证的推文、官方文档或对话原文。 |
| `<QuadrantPlot>` | **二维定位象限图**：极简细线坐标轴 + 真实官方 Logo 节点（`logoSrc`）+ 定位标签，用于模型/产品格局对比与视觉隐喻。 |
| `<StageFrame>` | 默认按 1920 逻辑宽等比缩放（`normalizeTo1920 = true`），一次布局即可在 1080p / 3K / 4K 保持一致字号与视觉占比；`header` 槽锁定在顶部安全区。 |
| `<WorldCamera keys={...}>` | **3D 世界相机**：每个 key 支持 `{ frame, cx, cy, scale, rotateX?, rotateY?, rotateZ? }`；默认开启 `perspective={1800}` 与轻柔云台微呼吸 `floatAmount={0.65}`；可选 `parallaxBackground` 获得 `0.42×` 远景视差。 |
| `springIn` / `springMorph` | `springIn(frame, fps, delay?, config?)` 与 `springMorph(frame, fps, triggerFrame, from, to, config?)`：真实 Remotion 弹簧物理，用于入场与同幕重排变形。 |
| `<MacWindowStage>` | 浅灰顶栏 macOS 真实录屏/网页展示舞台，传 `videoSrc="library/..."` 与 `loopFrames` 直接播放素材库视频。 |
| `<MonoFootnote>` / `<CornerBadge>` / `<TopStepperBar>` | 等宽溯源注脚、常驻话题徽章与顶部步骤条；`<SpokenMicroPill>` / `<VectorIcon>` / `<LiquidMeter>` 仅作为克制点缀，勿堆砌发光胶囊。 |
| `defaultTheme` / `SAFE_ZONES` | 深炭黑杂志风权威色板；顶部 HUD `0.12`、底部字幕安全区 `0.14`、左右边距 `0.05`。 |

## 常用命令

- `node sw-motion.mjs validate`：校验 manifest 时间范围、重叠、`matte` 取值与字幕安全区。
- `node sw-motion.mjs inspect`（定向微调加 `--shots Act1,HeroTitle`）：TypeScript 检查 + 并发出关键帧 + 自动拼出 `out/inspect/contact-sheet-*.jpg`。
- `node sw-motion.mjs render`：按 `files` 内容哈希复用 `.sw-cache/` 缓存，透明叠层自动走 ProRes 4444 alpha，叠加按需 Vision 抠像与无重影平滑转场，硬件编码输出 `motion-pending.mp4`。
