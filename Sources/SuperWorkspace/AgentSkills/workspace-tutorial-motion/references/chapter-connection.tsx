import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {WorldCamera, type CameraKey} from './world-camera';

// Example composition: 960 × 540, 30 fps, at least 60 frames.
// Replace labels, coordinates and narration beats together when adapting it.
const width = 960;
const height = 540;
const previous = {x: 300, y: 270};
const current = {x: 1100, y: 270};
const leave = 16;
const arrive = 46;
const cardWidth = 280;
const cardHeight = 132;
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
      border: `2px solid ${active ? '#6de3e8' : '#385268'}`, borderRadius: 18,
      background: active ? '#183742' : '#172636', color: '#f2f7fa', fontSize: 34,
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
    <AbsoluteFill style={{background: '#0c1724', fontFamily: 'sans-serif'}}>
      <WorldCamera viewportWidth={width} viewportHeight={height} keys={camera}>
        <svg width={1400} height={height} style={{position: 'absolute', inset: 0}}>
          <line x1={routeStart} x2={routeEnd} y1={current.y} y2={previous.y} stroke="#385268" strokeWidth={3} />
          <line x1={routeStart} x2={tipX} y1={current.y} y2={tipY} stroke="#6de3e8" strokeWidth={4} />
          <circle cx={tipX} cy={tipY} r={7} fill="#6de3e8" />
        </svg>
        <Card {...previous} label="输入" active={progress === 1} />
        <Card {...current} label="结果" active={progress === 0} />
      </WorldCamera>
      <div style={{position: 'absolute', left: 40, top: 32, color: '#f2f7fa', fontSize: 22}}>
        追溯结果的来源
      </div>
    </AbsoluteFill>
  );
};
