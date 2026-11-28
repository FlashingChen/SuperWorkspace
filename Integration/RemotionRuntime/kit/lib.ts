import {interpolate, spring} from 'remotion';

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

/** Snappy editorial spring (0 -> 1 with organic overshoot & settle). */
export const springIn = (
  frame: number,
  fps: number,
  delay = 0,
  config: {damping?: number; stiffness?: number; mass?: number} = {
    damping: 14,
    stiffness: 165,
    mass: 0.75,
  },
): number => {
  if (frame < delay) return 0;
  return spring({frame: frame - delay, fps, config});
};

/** Smoothly morphs a numeric value (x, y, scale, width) on triggerFrame with spring physics. */
export const springMorph = (
  frame: number,
  fps: number,
  triggerFrame: number,
  from: number,
  to: number,
  config: {damping?: number; stiffness?: number; mass?: number} = {
    damping: 16,
    stiffness: 135,
    mass: 0.85,
  },
): number => {
  const p = springIn(frame, fps, triggerFrame, config);
  return from + (to - from) * p;
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
