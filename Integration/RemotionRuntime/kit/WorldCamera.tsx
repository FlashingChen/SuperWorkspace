import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';

export type CameraKey = {
  frame: number;
  cx: number;
  cy: number;
  scale: number;
};

export interface WorldCameraProps {
  viewportWidth?: number;
  viewportHeight?: number;
  width?: number;
  height?: number;
  keys: CameraKey[];
  children: React.ReactNode;
}

/**
 * Virtual camera operating in world coordinates.
 * World objects keep fixed coordinates; only the camera viewport moves and scales.
 * Defaults viewport dimensions to `useVideoConfig()` and accepts both
 * `viewportWidth`/`viewportHeight` and `width`/`height` aliases.
 */
export const WorldCamera: React.FC<WorldCameraProps> = ({
  viewportWidth,
  viewportHeight,
  width,
  height,
  keys,
  children,
}) => {
  const frame = useCurrentFrame();
  const config = useVideoConfig();
  const vw = viewportWidth ?? width ?? config.width;
  const vh = viewportHeight ?? height ?? config.height;

  if (!Number.isFinite(vw) || !Number.isFinite(vh) || vw <= 0 || vh <= 0) {
    throw new Error(`WorldCamera requires positive finite viewport dimensions (got ${vw}x${vh})`);
  }
  if (keys.length === 0) {
    throw new Error('WorldCamera requires at least one CameraKey');
  }
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (
      !Number.isFinite(k.frame) ||
      !Number.isFinite(k.cx) ||
      !Number.isFinite(k.cy) ||
      !Number.isFinite(k.scale) ||
      k.scale <= 0 ||
      (i > 0 && k.frame <= keys[i - 1].frame)
    ) {
      throw new Error('CameraKey coordinates must be finite, scales positive, and frames strictly increasing');
    }
  }

  let a = keys[0];
  let b = keys[0];
  if (frame >= keys[keys.length - 1].frame) {
    a = b = keys[keys.length - 1];
  } else if (frame > keys[0].frame) {
    const next = keys.findIndex((key) => key.frame >= frame);
    a = keys[next - 1];
    b = keys[next];
  }
  const t =
    a.frame === b.frame
      ? 0
      : interpolate(frame, [a.frame, b.frame], [0, 1], {
          extrapolateLeft: 'clamp',
          extrapolateRight: 'clamp',
        });
  const eased = t * t * (3 - 2 * t);
  const mix = (x: number, y: number) => x + (y - x) * eased;
  const cx = mix(a.cx, b.cx);
  const cy = mix(a.cy, b.cy);
  const scale = mix(a.scale, b.scale);
  const tx = vw / 2 - cx * scale;
  const ty = vh / 2 - cy * scale;

  if (!Number.isFinite(tx) || !Number.isFinite(ty) || !Number.isFinite(scale)) {
    throw new Error(`WorldCamera computed non-finite transform (${tx}, ${ty}, ${scale})`);
  }

  return (
    <AbsoluteFill style={{overflow: 'hidden'}} data-sw-role="camera-viewport">
      <div
        data-sw-role="camera-world"
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          width: vw,
          height: vh,
          transformOrigin: '0 0',
          transform: `translate(${tx}px, ${ty}px) scale(${scale})`,
        }}
      >
        {children}
      </div>
    </AbsoluteFill>
  );
};
