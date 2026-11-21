import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';

export type CameraKey = {
  frame: number;
  cx: number;
  cy: number;
  scale: number;
};

/**
 * Virtual camera operating in world coordinates.
 * World objects keep fixed coordinates; only the camera viewport moves and scales.
 * Fixed headers and subtitles should live outside WorldCamera.
 */
export const WorldCamera: React.FC<{
  viewportWidth: number;
  viewportHeight: number;
  keys: CameraKey[];
  children: React.ReactNode;
}> = ({viewportWidth, viewportHeight, keys, children}) => {
  const frame = useCurrentFrame();
  if (keys.length === 0) {
    throw new Error('WorldCamera requires at least one CameraKey');
  }
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].scale <= 0 || (i > 0 && keys[i].frame <= keys[i - 1].frame)) {
      throw new Error('CameraKey scales must be positive and frames strictly increasing');
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

  return (
    <AbsoluteFill style={{overflow: 'hidden'}} data-sw-role="camera-viewport">
      <div
        data-sw-role="camera-world"
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          width: viewportWidth,
          height: viewportHeight,
          transformOrigin: '0 0',
          transform: `translate(${viewportWidth / 2 - cx * scale}px, ${viewportHeight / 2 - cy * scale}px) scale(${scale})`,
        }}
      >
        {children}
      </div>
    </AbsoluteFill>
  );
};
