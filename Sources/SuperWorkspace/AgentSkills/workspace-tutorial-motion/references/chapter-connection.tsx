import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {WorldCamera, defaultTheme, type CameraKey} from '../sw-kit';

// Example composition: 1920 × 1080, 60 fps.
// Replace labels, coordinates and narration beats together when adapting it.
const previous = {x: 560, y: 540};
const current = {x: 1520, y: 540};
const leave = 30;
const arrive = 90;
const cardWidth = 360;
const cardHeight = 160;
const routeStart = current.x - cardWidth / 2;
const routeEnd = previous.x + cardWidth / 2;
const camera: CameraKey[] = [
  {frame: leave, cx: current.x, cy: current.y, scale: 1},
  {frame: (leave + arrive) / 2, cx: (current.x + previous.x) / 2, cy: (current.y + previous.y) / 2, scale: 0.78},
  {frame: arrive, cx: previous.x, cy: previous.y, scale: 1},
];
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

const Card: React.FC<{x: number; y: number; label: string; active: boolean}> =
  ({x, y, label, active}) => (
    <div style={{
      position: 'absolute', left: x - cardWidth / 2, top: y - cardHeight / 2,
      width: cardWidth, height: cardHeight, boxSizing: 'border-box',
      display: 'grid', placeItems: 'center',
      border: `2px solid ${active ? defaultTheme.cyan : defaultTheme.borderStrong}`,
      borderRadius: 18,
      background: active ? defaultTheme.surfaceAlt : defaultTheme.surface,
      color: defaultTheme.text,
      fontSize: 38,
      fontWeight: 700,
    }}>
      {label}
    </div>
  );

export const ChapterConnection: React.FC = () => {
  const frame = useCurrentFrame();
  const progress = interpolate(frame, [leave, arrive], [0, 1], clamp);
  const tipX = routeStart + (routeEnd - routeStart) * progress;
  const tipY = current.y + (previous.y - current.y) * progress;
  return (
    <AbsoluteFill style={{background: defaultTheme.bg, fontFamily: defaultTheme.fontSans}}>
      <WorldCamera keys={camera}>
        <svg width={2100} height={1080} style={{position: 'absolute', inset: 0}}>
          <line x1={routeStart} x2={routeEnd} y1={current.y} y2={previous.y} stroke={defaultTheme.borderStrong} strokeWidth={3} />
          <line x1={routeStart} x2={tipX} y1={current.y} y2={tipY} stroke={defaultTheme.cyan} strokeWidth={4} />
          <circle cx={tipX} cy={tipY} r={8} fill={defaultTheme.cyan} />
        </svg>
        <Card {...previous} label="输入" active={progress === 1} />
        <Card {...current} label="结果" active={progress === 0} />
      </WorldCamera>
      <div style={{position: 'absolute', left: 56, top: 44, color: defaultTheme.textMuted, fontSize: 24, fontWeight: 600}}>
        追溯结果的来源
      </div>
    </AbsoluteFill>
  );
};
