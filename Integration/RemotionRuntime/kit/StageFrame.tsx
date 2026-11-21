import React from 'react';
import {AbsoluteFill, useVideoConfig} from 'remotion';
import {defaultTheme, MotionTheme, SAFE_ZONES} from './theme';

export interface StageFrameProps {
  theme?: MotionTheme;
  background?: React.ReactNode;
  header?: React.ReactNode;
  headerScrim?: boolean;
  reserveSubtitleZone?: boolean;
  children: React.ReactNode;
}

/**
 * Standard 3-layer editorial stage:
 *   1. background (never moves with camera)
 *   2. children (cameraWorld + objects)
 *   3. fixed header (with optional top scrim so world objects never clash with titles)
 *
 * Includes `data-sw-role` markers used by `sw-motion.mjs inspect` for automatic
 * overlap and safe-zone geometry checks.
 */
export const StageFrame: React.FC<StageFrameProps> = ({
  theme = defaultTheme,
  background,
  header,
  headerScrim = true,
  reserveSubtitleZone = true,
  children,
}) => {
  const {width, height} = useVideoConfig();
  const topHeight = Math.round(height * SAFE_ZONES.topHeaderRatio);
  const bottomHeight = Math.round(height * SAFE_ZONES.bottomSubtitleRatio);
  const padX = Math.round(width * SAFE_ZONES.sideMarginRatio);

  return (
    <AbsoluteFill
      data-sw-role="stage"
      style={{
        backgroundColor: theme.bg,
        color: theme.text,
        fontFamily: theme.fontSans,
        overflow: 'hidden',
      }}
    >
      <AbsoluteFill data-sw-role="background">{background}</AbsoluteFill>
      <AbsoluteFill data-sw-role="content">{children}</AbsoluteFill>
      {header ? (
        <div
          data-sw-role="header"
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            top: 0,
            height: topHeight,
            paddingLeft: padX,
            paddingRight: padX,
            display: 'flex',
            alignItems: 'center',
            pointerEvents: 'none',
            background: headerScrim
              ? `linear-gradient(180deg, ${theme.bg}e8 0%, ${theme.bg}99 68%, transparent 100%)`
              : undefined,
          }}
        >
          {header}
        </div>
      ) : null}
      {reserveSubtitleZone ? (
        <div
          data-sw-role="subtitle-safe"
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            bottom: 0,
            height: bottomHeight,
            pointerEvents: 'none',
          }}
        />
      ) : null}
    </AbsoluteFill>
  );
};
