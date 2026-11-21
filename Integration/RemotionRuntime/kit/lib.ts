import {interpolate} from 'remotion';

export const clamp01 = (v: number): number => Math.max(0, Math.min(1, v));

export const easeOutCubic = (t: number): number => {
  const c = clamp01(t);
  return 1 - Math.pow(1 - c, 3);
};

export const easeInOutCubic = (t: number): number => {
  const c = clamp01(t);
  return c < 0.5 ? 4 * c * c * c : 1 - Math.pow(-2 * c + 2, 3) / 2;
};

export const ease = (frame: number, start: number, end: number): number => {
  if (end <= start) return frame >= start ? 1 : 0;
  const t = interpolate(frame, [start, end], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return easeInOutCubic(t);
};

export const pop = (
  frame: number,
  start: number,
  duration = 16,
): {opacity: number; scale: number; progress: number} => {
  const progress = easeOutCubic((frame - start) / Math.max(1, duration));
  return {
    progress,
    opacity: clamp01(progress * 1.25),
    scale: 0.92 + 0.08 * progress,
  };
};

export const stagger = (index: number, stepFrames = 6, baseFrame = 0): number =>
  baseFrame + Math.max(0, index) * stepFrames;

export const secToFrames = (seconds: number, fps: number): number =>
  Math.max(1, Math.round(seconds * fps));
