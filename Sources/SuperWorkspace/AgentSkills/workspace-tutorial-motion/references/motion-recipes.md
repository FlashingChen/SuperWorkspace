# 3D 世界相机运镜与连续图解示例

## 输入 → 处理 → 结果（3D 大世界画布）

在一个连续画布上布置所有节点，用 **3D `WorldCamera`** 执行推进（Dolly In）、摇镜（Pan/Tilt）、3D 倾角（`rotateX`/`rotateY`）与拉回（Pull Back），不为每个阶段重建孤立静态卡片：

| 节拍 | 对象动作（`springIn` / `springMorph`） | 3D 摄像机（`WorldCamera`） |
| --- | --- | --- |
| 建立 | 主体弹性入场，交代方向与结构 | 略宽建立全景（`scale: 0.94`, `rotateY: 4°`） |
| 聚焦 | 焦点模块高亮，次要项 `dimmed` 降噪 | 推近焦点（`scale: 1.22`, `rotateY: -8°`, `rotateX: 3°`） |
| 流转 | 元素沿连线流动或用 `springMorph` 物理重排 | 沿流向平滑摇镜（改 `cx/cy` + 反转 `rotateY` 视角） |
| 实证 | 真实录屏窗口或查证指标跳动展开 | 推近核心操作区或数据条，`MonoFootnote` 标注出处 |
| 收束 | 关键结论高亮定格 | 拉回全景（`scale: 0.96`, `rotateY: 0°`）承接下一幕 |

## 3D 相机与液态玻璃 HUD 模板

```tsx
import React from 'react';
import {
  StageFrame,
  WorldCamera,
  CornerBadge,
  MonoFootnote,
  type CameraKey,
} from '../sw-kit';

const camera: CameraKey[] = [
  {frame: 0,   cx: 960,  cy: 540, scale: 0.94, rotateY: 4,  rotateX: 2,  rotateZ: -0.4},
  {frame: 50,  cx: 740,  cy: 480, scale: 1.22, rotateY: -8, rotateX: 3,  rotateZ: 0.5},
  {frame: 140, cx: 1220, cy: 560, scale: 1.20, rotateY: 8,  rotateX: -3, rotateZ: -0.4},
  {frame: 220, cx: 960,  cy: 540, scale: 0.96, rotateY: 0,  rotateX: 0,  rotateZ: 0},
];

export const DiagramShot: React.FC = () => (
  <StageFrame header={<CornerBadge title="CORE ARCHITECTURE" subtitle="核心能力拆解" />}>
    {/* 1. 3D 相机世界：对象、连线、真实录屏舞台随相机推拉与倾角运动，自带云台微呼吸 */}
    <WorldCamera keys={camera} floatAmount={0.65}>
      {/* 世界坐标对象层 */}
    </WorldCamera>
    {/* 2. 锁定 HUD 溯源注脚（不随相机；底部 14% 留给宿主字幕） */}
    <MonoFootnote text="SOURCE: OFFICIAL DOCS" bottom={164} />
  </StageFrame>
);
```

跨章节回指可直接参考 [chapter-connection.tsx](chapter-connection.tsx)：出发帧对齐口播提到关联的那一刻，让连线生长与相机回移同步完成。
