import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {StageDimensionsContext} from './StageFrame';

export type CameraKey = {
  frame: number;
  cx: number;
  cy: number;
  scale: number;
  /** Optional 3D pitch tilt in degrees (default 0). */
  rotateX?: number;
  /** Optional 3D yaw tilt in degrees (default 0). */
  rotateY?: number;
  /** Optional subtle roll in degrees (default 0). */
  rotateZ?: number;
};

export interface WorldCameraProps {
  viewportWidth?: number;
  viewportHeight?: number;
  width?: number;
  height?: number;
  /** CSS 3D perspective depth in px (default 1800). */
  perspective?: number;
  /** Organic gimbal micro-float multiplier (default 0.65; set 0 to disable). */
  floatAmount?: number;
  /** Optional far-plane backdrop receiving 0.42x camera parallax for 3-layer depth. */
  parallaxBackground?: React.ReactNode;
  keys: CameraKey[];
  children: React.ReactNode;
}

/**
 * 3D Virtual World Camera operating in logical world coordinates.
 * World objects keep fixed coordinates while the camera dollies, pans, tilts in 3D,
 * and adds subtle organic gimbal breathing so frames never feel dead-locked.
 */
export const WorldCamera: React.FC<WorldCameraProps> = ({
  viewportWidth,
  viewportHeight,
  width,
  height,
  perspective = 1800,
  floatAmount = 0.65,
  parallaxBackground,
  keys,
  children,
}) => {
  const frame = useCurrentFrame();
  const config = useVideoConfig();
  const stage = React.useContext(StageDimensionsContext);
  const vw = viewportWidth ?? width ?? stage?.width ?? config.width;
  const vh = viewportHeight ?? height ?? stage?.height ?? config.height;

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

  const sec = frame / Math.max(1, config.fps);
  const floatScale = Number.isFinite(floatAmount) ? Math.max(0, floatAmount) : 0;
  const floatX = Math.sin(sec * 0.72) * 5 * floatScale;
  const floatY = Math.cos(sec * 0.56) * 3.5 * floatScale;
  const floatRotY = Math.sin(sec * 0.48) * 0.45 * floatScale;
  const floatRotX = Math.cos(sec * 0.62) * 0.3 * floatScale;
  const floatRotZ = Math.sin(sec * 0.37) * 0.16 * floatScale;

  const cx = mix(a.cx, b.cx);
  const cy = mix(a.cy, b.cy);
  const scale = mix(a.scale, b.scale);
  const rotX = mix(a.rotateX ?? 0, b.rotateX ?? 0) + floatRotX;
  const rotY = mix(a.rotateY ?? 0, b.rotateY ?? 0) + floatRotY;
  const rotZ = mix(a.rotateZ ?? 0, b.rotateZ ?? 0) + floatRotZ;
  const tx = vw / 2 - cx * scale + floatX;
  const ty = vh / 2 - cy * scale + floatY;

  if (!Number.isFinite(tx) || !Number.isFinite(ty) || !Number.isFinite(scale)) {
    throw new Error(`WorldCamera computed non-finite transform (${tx}, ${ty}, ${scale})`);
  }

  const parallaxTx = (vw / 2 - cx) * 0.42 + floatX * 0.42;
  const parallaxTy = (vh / 2 - cy) * 0.42 + floatY * 0.42;
  const parallaxScale = 1 + (scale - 1) * 0.35;

  return (
    <AbsoluteFill
      style={{
        overflow: 'hidden',
        perspective: `${perspective}px`,
        perspectiveOrigin: '50% 50%',
      }}
      data-sw-role="camera-viewport"
    >
      {parallaxBackground ? (
        <div
          data-sw-role="camera-parallax-bg"
          style={{
            position: 'absolute',
            inset: '-10%',
            transformOrigin: '50% 50%',
            transform: `translate3d(${parallaxTx}px, ${parallaxTy}px, 0) scale(${parallaxScale})`,
            pointerEvents: 'none',
          }}
        >
          {parallaxBackground}
        </div>
      ) : null}
      <div
        data-sw-role="camera-3d-rig"
        style={{
          position: 'absolute',
          inset: 0,
          transformStyle: 'preserve-3d',
          transformOrigin: '50% 50%',
          transform: `rotateX(${rotX}deg) rotateY(${rotY}deg) rotateZ(${rotZ}deg)`,
        }}
      >
        <div
          data-sw-role="camera-world"
          style={{
            position: 'absolute',
            left: 0,
            top: 0,
            width: vw,
            height: vh,
            transformStyle: 'preserve-3d',
            transformOrigin: '0 0',
            transform: `translate3d(${tx}px, ${ty}px, 0) scale(${scale})`,
          }}
        >
          {children}
        </div>
      </div>
    </AbsoluteFill>
  );
};
