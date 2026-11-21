import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {defaultTheme, MotionTheme} from './theme';

export interface MediaCardProps {
  theme?: MotionTheme;
  width: number;
  height: number;
  title?: string;
  accent?: string;
  pushIn?: number;
  children: React.ReactNode;
}

/**
 * Framed container for reference screenshots, videos, or diagrams.
 * Preserves aspect ratio inside a styled bezel with subtle continuous push-in.
 */
export const MediaCard: React.FC<MediaCardProps> = ({
  theme = defaultTheme,
  width,
  height,
  title,
  accent,
  pushIn = 0.03,
  children,
}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const progress = Math.min(1, Math.max(0, frame / Math.max(1, durationInFrames)));
  const scale = 1 + pushIn * progress;
  const rim = accent ?? theme.borderStrong;

  return (
    <div
      data-sw-role="card"
      style={{
        width,
        height,
        borderRadius: 20,
        background: theme.surface,
        border: `2px solid ${rim}`,
        boxShadow: '0 24px 64px rgba(0, 0, 0, 0.45)',
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
      }}
    >
      {title ? (
        <div
          style={{
            height: 44,
            padding: '0 18px',
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            borderBottom: `1px solid ${theme.border}`,
            background: theme.bgElevated,
            fontFamily: theme.fontMono,
            fontSize: 16,
            color: theme.textMuted,
            flexShrink: 0,
          }}
        >
          <span
            style={{
              width: 10,
              height: 10,
              borderRadius: 5,
              background: accent ?? theme.cyan,
            }}
          />
          <span style={{overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap'}}>
            {title}
          </span>
        </div>
      ) : null}
      <div
        style={{
          flex: 1,
          position: 'relative',
          overflow: 'hidden',
          background: theme.bgElevated,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        <div
          style={{
            width: '100%',
            height: '100%',
            transform: `scale(${scale})`,
            transformOrigin: 'center center',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          {children}
        </div>
      </div>
    </div>
  );
};

export interface PhoneMockupProps {
  theme?: MotionTheme;
  width: number;
  height: number;
  accent?: string;
  children: React.ReactNode;
}

/**
 * Clean phone bezel for vertical screen recordings or mobile UI captures.
 */
export const PhoneMockup: React.FC<PhoneMockupProps> = ({
  theme = defaultTheme,
  width,
  height,
  accent,
  children,
}) => {
  const bezel = Math.max(10, Math.round(width * 0.032));
  const outerRadius = Math.max(28, Math.round(width * 0.11));
  const innerRadius = Math.max(18, outerRadius - bezel);

  return (
    <div
      data-sw-role="card"
      style={{
        width,
        height,
        borderRadius: outerRadius,
        padding: bezel,
        background: theme.bgElevated,
        border: `2px solid ${accent ?? theme.borderStrong}`,
        boxShadow: '0 30px 80px rgba(0, 0, 0, 0.55)',
        boxSizing: 'border-box',
        position: 'relative',
      }}
    >
      <div
        style={{
          width: '100%',
          height: '100%',
          borderRadius: innerRadius,
          overflow: 'hidden',
          background: theme.bg,
          position: 'relative',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        {children}
      </div>
    </div>
  );
};
