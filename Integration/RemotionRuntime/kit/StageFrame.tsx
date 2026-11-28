import React from 'react';
import {AbsoluteFill, useVideoConfig} from 'remotion';
import {defaultTheme, MotionTheme, SAFE_ZONES} from './theme';

export const StageDimensionsContext = React.createContext<{width: number; height: number} | null>(null);

export interface StageFrameProps {
  theme?: MotionTheme;
  background?: React.ReactNode;
  header?: React.ReactNode;
  headerScrim?: boolean;
  reserveSubtitleZone?: boolean;
  /**
   * When true (default), authors content in a normalized 1920-wide logical coordinate system
   * and scales proportionally to fill 1080p, Retina 3K (3024×1740), or 4K canvases edge-to-edge
   * so cards and typography never shrink into tiny postage stamps on high-DPI recordings.
   */
  normalizeTo1920?: boolean;
  children: React.ReactNode;
}

const DefaultEditorialBackdrop: React.FC<{theme: MotionTheme}> = ({theme}) => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(ellipse 75% 65% at 42% 38%, ${theme.bgElevated} 0%, ${theme.bg} 72%, #06070b 100%)`,
    }}
  >
    <AbsoluteFill
      style={{
        backgroundImage: 'radial-gradient(rgba(255, 255, 255, 0.055) 1px, transparent 1px)',
        backgroundSize: '36px 36px',
        opacity: 0.65,
      }}
    />
  </AbsoluteFill>
);

/**
 * Standard 3-layer editorial stage:
 *   1. background (never moves with camera; defaults to subtle dark-studio spotlight + micro-dot grid)
 *   2. children (cameraWorld + objects, automatically scaled from 1920 logical width by default)
 *   3. fixed header (with optional top scrim so world objects never clash with titles)
 */
export const StageFrame: React.FC<StageFrameProps> = ({
  theme = defaultTheme,
  background,
  header,
  headerScrim = true,
  reserveSubtitleZone = true,
  normalizeTo1920 = true,
  children,
}) => {
  const {width, height} = useVideoConfig();
  const scale = normalizeTo1920 ? width / 1920 : 1;
  const logicalW = normalizeTo1920 ? 1920 : width;
  const logicalH = normalizeTo1920 ? Math.round(height / scale) : height;
  const topHeight = Math.round(logicalH * SAFE_ZONES.topHeaderRatio);
  const bottomHeight = Math.round(logicalH * SAFE_ZONES.bottomSubtitleRatio);
  const padX = Math.round(logicalW * SAFE_ZONES.sideMarginRatio);

  const stageBody = (
    <div
      data-sw-role="stage"
      style={{
        position: 'relative',
        width: logicalW,
        height: logicalH,
        backgroundColor: theme.bg,
        color: theme.text,
        fontFamily: theme.fontSans,
        overflow: 'hidden',
        transform: normalizeTo1920 ? `scale(${scale})` : undefined,
        transformOrigin: 'top left',
      }}
    >
      <AbsoluteFill data-sw-role="background">
        {background ?? <DefaultEditorialBackdrop theme={theme} />}
      </AbsoluteFill>
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
    </div>
  );

  return (
    <StageDimensionsContext.Provider value={{width: logicalW, height: logicalH}}>
      <AbsoluteFill style={{overflow: 'hidden', backgroundColor: theme.bg}}>{stageBody}</AbsoluteFill>
    </StageDimensionsContext.Provider>
  );
};
