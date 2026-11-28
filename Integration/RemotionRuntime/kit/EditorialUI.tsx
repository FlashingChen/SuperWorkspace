import React from 'react';
import {interpolate, Loop, OffthreadVideo, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {defaultTheme} from './theme';

export type VectorIconName =
  | 'check'
  | 'ban'
  | 'x'
  | 'bolt'
  | 'globe'
  | 'sparkle'
  | 'terminal'
  | 'download'
  | 'play'
  | 'arrowDown'
  | 'shield'
  | 'layers';

export const VectorIcon: React.FC<{name: VectorIconName; color: string; size?: number}> = ({
  name,
  color,
  size = 18,
}) => {
  const common = {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: color,
    strokeWidth: 2,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    style: {flexShrink: 0},
  };

  switch (name) {
    case 'check':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9.5" />
          <path d="M8.5 12.2l2.4 2.4 4.8-5.2" />
        </svg>
      );
    case 'ban':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9.5" />
          <path d="M5.5 5.5l13 13" />
        </svg>
      );
    case 'x':
      return (
        <svg {...common}>
          <path d="M17 7L7 17M7 7l10 10" />
        </svg>
      );
    case 'bolt':
      return (
        <svg {...common}>
          <path d="M13 2L4.5 13.5H12L11 22l8.5-11.5H12L13 2z" />
        </svg>
      );
    case 'globe':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9.5" />
          <path d="M2.5 12h19M12 2.5a14 14 0 010 19M12 2.5a14 14 0 000 19" />
        </svg>
      );
    case 'sparkle':
      return (
        <svg {...common}>
          <path d="M12 3l2.2 6.8L21 12l-6.8 2.2L12 21l-2.2-6.8L3 12l6.8-2.2L12 3z" />
        </svg>
      );
    case 'terminal':
      return (
        <svg {...common}>
          <rect x="3" y="4" width="18" height="16" rx="3" />
          <path d="M7.5 9.5l3 2.5-3 2.5M12.5 14.5h4" />
        </svg>
      );
    case 'download':
      return (
        <svg {...common}>
          <path d="M12 4v11m0 0l-4-4m4 4l4-4M5 19h14" />
        </svg>
      );
    case 'play':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9.5" />
          <path d="M10 8.8l5.5 3.2-5.5 3.2V8.8z" fill={color} stroke="none" />
        </svg>
      );
    case 'arrowDown':
      return (
        <svg {...common}>
          <path d="M12 5v14m0 0l-5-5m5 5l5-5" />
        </svg>
      );
    case 'shield':
      return (
        <svg {...common}>
          <path d="M12 3l7.5 3v6c0 4.5-3.2 7.8-7.5 9-4.3-1.2-7.5-4.5-7.5-9V6L12 3z" />
          <path d="M9 12l2 2 4-4" />
        </svg>
      );
    case 'layers':
      return (
        <svg {...common}>
          <path d="M12 3l9 4.5-9 4.5-9-4.5L12 3z" />
          <path d="M3 12l9 4.5 9-4.5" />
          <path d="M3 16.5L12 21l9-4.5" />
        </svg>
      );
  }
};

export type PillVariant = 'dark' | 'darkRed' | 'darkCyan' | 'solidRed' | 'solidGold' | 'solidCyan';

const PILL_STYLES: Record<PillVariant, {bg: string; border: string; text: string; icon: string; glass?: boolean}> = {
  dark: {
    bg: 'linear-gradient(135deg, rgba(255,255,255,0.16) 0%, rgba(255,255,255,0.04) 50%, rgba(12,16,26,0.48) 100%)',
    border: 'rgba(255,255,255,0.30)',
    text: '#F8FAFC',
    icon: '#E2E8F0',
    glass: true,
  },
  darkRed: {
    bg: 'linear-gradient(135deg, rgba(239,68,68,0.24) 0%, rgba(22,12,14,0.58) 100%)',
    border: 'rgba(248,113,113,0.52)',
    text: '#FFFFFF',
    icon: '#F87171',
    glass: true,
  },
  darkCyan: {
    bg: 'linear-gradient(135deg, rgba(34,211,238,0.22) 0%, rgba(10,20,28,0.56) 100%)',
    border: 'rgba(103,232,249,0.48)',
    text: '#E0F9FF',
    icon: '#22D3EE',
    glass: true,
  },
  solidRed: {bg: '#EF4444', border: '#EF4444', text: '#FFFFFF', icon: '#FFFFFF'},
  solidGold: {bg: '#FACC15', border: '#FACC15', text: '#090B10', icon: '#090B10'},
  solidCyan: {bg: '#22D3EE', border: '#22D3EE', text: '#090B10', icon: '#090B10'},
};

export interface SpokenMicroPillProps {
  icon?: VectorIconName;
  label: string;
  startFrame?: number;
  variant?: PillVariant;
  dimmed?: boolean;
  size?: 'sm' | 'md' | 'lg';
}

export const SpokenMicroPill: React.FC<SpokenMicroPillProps> = ({
  icon,
  label,
  startFrame = 0,
  variant = 'dark',
  dimmed = false,
  size = 'md',
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  if (frame < startFrame) return null;

  const p = spring({
    frame: frame - startFrame,
    fps,
    config: {damping: 16, stiffness: 220, mass: 0.65},
  });
  const s = PILL_STYLES[variant];
  const fontSize = size === 'lg' ? 24 : size === 'sm' ? 17 : 20;
  const pad = size === 'lg' ? '11px 24px' : size === 'sm' ? '7px 16px' : '9px 20px';
  const iconSize = size === 'lg' ? 21 : size === 'sm' ? 16 : 19;

  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 9,
        padding: pad,
        borderRadius: 999,
        background: s.bg,
        backdropFilter: s.glass ? 'blur(22px) saturate(175%)' : undefined,
        WebkitBackdropFilter: s.glass ? 'blur(22px) saturate(175%)' : undefined,
        border: `1.2px solid ${s.border}`,
        boxShadow: s.glass
          ? 'inset 0 1.2px 1px rgba(255,255,255,0.45), inset 0 -1px 1.5px rgba(255,255,255,0.12), 0 12px 30px rgba(0,0,0,0.36)'
          : '0 10px 28px rgba(0,0,0,0.42)',
        opacity: (dimmed ? 0.36 : 1) * p,
        transform: `translateY(${interpolate(p, [0, 1], [12, 0])}px) scale(${interpolate(p, [0, 1], [0.94, 1])})`,
        fontFamily: defaultTheme.fontSans,
        width: 'fit-content',
      }}
    >
      {icon ? <VectorIcon name={icon} color={s.icon} size={iconSize} /> : null}
      <span style={{fontSize, fontWeight: 700, color: s.text, letterSpacing: '0.02em', whiteSpace: 'nowrap'}}>
        {label}
      </span>
    </div>
  );
};

export interface CornerBadgeProps {
  title: string;
  subtitle: string;
  accent?: string;
}

/** Liquid Glass persistent topic badge anchored cleanly in the top-left HUD zone. */
export const CornerBadge: React.FC<CornerBadgeProps> = ({title, subtitle, accent = '#FACC15'}) => (
  <div
    style={{
      position: 'relative',
      display: 'inline-flex',
      alignItems: 'center',
      gap: 15,
      padding: '13px 28px 13px 20px',
      borderRadius: 999,
      background:
        'linear-gradient(135deg, rgba(255,255,255,0.22) 0%, rgba(255,255,255,0.06) 48%, rgba(12,16,26,0.42) 100%)',
      backdropFilter: 'blur(24px) saturate(185%)',
      WebkitBackdropFilter: 'blur(24px) saturate(185%)',
      border: '1.2px solid rgba(255,255,255,0.34)',
      boxShadow:
        'inset 0 1.5px 1.5px rgba(255,255,255,0.58), inset 0 -1.5px 2px rgba(255,255,255,0.14), 0 14px 36px rgba(0,0,0,0.38)',
      fontFamily: defaultTheme.fontSans,
      overflow: 'hidden',
    }}
  >
    <div
      style={{
        position: 'absolute',
        top: 0,
        left: 14,
        right: 14,
        height: '46%',
        borderRadius: '999px 999px 50% 50%',
        background: 'linear-gradient(180deg, rgba(255,255,255,0.22) 0%, rgba(255,255,255,0) 100%)',
        pointerEvents: 'none',
      }}
    />
    <div
      style={{
        width: 10,
        height: 10,
        borderRadius: 999,
        background: accent,
        boxShadow: `0 0 14px ${accent}, 0 0 4px #FFFFFF`,
        position: 'relative',
      }}
    />
    <div style={{display: 'flex', flexDirection: 'column', gap: 1, position: 'relative'}}>
      <span style={{fontSize: 15, fontWeight: 900, letterSpacing: '0.12em', color: accent}}>
        {title}
      </span>
      <span style={{fontSize: 20, fontWeight: 700, color: '#FFFFFF', letterSpacing: '0.02em'}}>
        {subtitle}
      </span>
    </div>
  </div>
);

export const MonoFootnote: React.FC<{text: string; bottom?: number; right?: number; left?: number}> = ({
  text,
  bottom = 18,
  right = 32,
  left,
}) => (
  <div
    style={{
      position: 'absolute',
      bottom,
      ...(left !== undefined ? {left} : {right}),
      zIndex: 42,
      fontFamily: defaultTheme.fontMono,
      fontSize: 13,
      fontWeight: 600,
      letterSpacing: '0.08em',
      color: 'rgba(148, 163, 184, 0.6)',
      textTransform: 'uppercase',
      pointerEvents: 'none',
    }}
  >
    {text}
  </div>
);

export type MeterTone = 'cyan' | 'red' | 'gold' | 'violet';

const METER_COLORS: Record<MeterTone, {fill: string; glow: string; text: string; border: string}> = {
  cyan: {
    fill: 'linear-gradient(90deg, #06B6D4 0%, #22D3EE 60%, #67E8F9 100%)',
    glow: 'rgba(34,211,238,0.55)',
    text: '#67E8F9',
    border: 'rgba(103,232,249,0.38)',
  },
  red: {
    fill: 'linear-gradient(90deg, #DC2626 0%, #EF4444 65%, #F87171 100%)',
    glow: 'rgba(239,68,68,0.55)',
    text: '#FCA5A5',
    border: 'rgba(248,113,113,0.44)',
  },
  gold: {
    fill: 'linear-gradient(90deg, #D97706 0%, #FACC15 100%)',
    glow: 'rgba(250,204,21,0.5)',
    text: '#FDE047',
    border: 'rgba(250,204,21,0.4)',
  },
  violet: {
    fill: 'linear-gradient(90deg, #7C3AED 0%, #A78BFA 100%)',
    glow: 'rgba(167,139,250,0.5)',
    text: '#DDD6FE',
    border: 'rgba(167,139,250,0.4)',
  },
};

export interface LiquidMeterProps {
  label: string;
  fromPct: number;
  toPct: number;
  startFrame?: number;
  animDurationFrames?: number;
  tone?: MeterTone;
  badgeText?: string;
  unit?: string;
  /** Qualitative label shown instead of numeric percentage when no verified number exists. */
  valueText?: string;
  width?: number | string;
  dimmed?: boolean;
}

export const LiquidMeter: React.FC<LiquidMeterProps> = ({
  label,
  fromPct,
  toPct,
  startFrame = 0,
  animDurationFrames = 70,
  tone = 'cyan',
  badgeText,
  unit = '%',
  valueText,
  width = '100%',
  dimmed = false,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  if (frame < startFrame) return null;

  const p = spring({
    frame: frame - startFrame,
    fps,
    config: {damping: 16, stiffness: 200, mass: 0.7},
  });
  const rawProgress = interpolate(frame - startFrame, [6, 6 + Math.max(1, animDurationFrames)], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const eased = 1 - Math.pow(1 - rawProgress, 3);
  const currentPct = fromPct + (toPct - fromPct) * eased;
  const c = METER_COLORS[tone];

  return (
    <div
      style={{
        width,
        padding: '16px 22px 18px 22px',
        borderRadius: 18,
        background:
          'linear-gradient(135deg, rgba(255,255,255,0.14) 0%, rgba(255,255,255,0.03) 48%, rgba(12,16,26,0.58) 100%)',
        backdropFilter: 'blur(22px) saturate(180%)',
        WebkitBackdropFilter: 'blur(22px) saturate(180%)',
        border: `1.2px solid ${c.border}`,
        boxShadow:
          'inset 0 1.2px 1px rgba(255,255,255,0.4), inset 0 -1px 1.5px rgba(255,255,255,0.1), 0 14px 34px rgba(0,0,0,0.42)',
        opacity: (dimmed ? 0.36 : 1) * p,
        transform: `translateY(${interpolate(p, [0, 1], [14, 0])}px) scale(${interpolate(p, [0, 1], [0.95, 1])})`,
        fontFamily: defaultTheme.fontSans,
      }}
    >
      <div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 11}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
          <span style={{fontSize: 22, fontWeight: 800, color: '#FFFFFF'}}>{label}</span>
          {badgeText ? (
            <span
              style={{
                fontSize: 14,
                fontWeight: 800,
                color: c.text,
                padding: '3px 10px',
                borderRadius: 999,
                background: 'rgba(0,0,0,0.36)',
                border: `1px solid ${c.border}`,
              }}
            >
              {badgeText}
            </span>
          ) : null}
        </div>
        <span
          style={{
            fontFamily: valueText ? defaultTheme.fontSans : defaultTheme.fontMono,
            fontSize: valueText ? 21 : 25,
            fontWeight: 800,
            color: c.text,
            fontVariantNumeric: 'tabular-nums',
          }}
        >
          {valueText ?? `${Math.round(currentPct)}${unit}`}
        </span>
      </div>
      <div
        style={{
          width: '100%',
          height: 11,
          borderRadius: 999,
          background: 'rgba(255,255,255,0.12)',
          overflow: 'hidden',
          boxShadow: 'inset 0 1px 3px rgba(0,0,0,0.5)',
        }}
      >
        <div
          style={{
            width: `${Math.max(3, Math.min(100, currentPct))}%`,
            height: '100%',
            borderRadius: 999,
            background: c.fill,
            boxShadow: `0 0 14px ${c.glow}`,
          }}
        />
      </div>
    </div>
  );
};

export interface StepperItem {
  id: string;
  label: string;
}

export const TopStepperBar: React.FC<{steps: StepperItem[]; activeIndex: number}> = ({steps, activeIndex}) => (
  <div
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 14,
      padding: '10px 24px',
      borderRadius: 999,
      background:
        'linear-gradient(135deg, rgba(255,255,255,0.18) 0%, rgba(255,255,255,0.05) 50%, rgba(12,16,26,0.44) 100%)',
      backdropFilter: 'blur(24px) saturate(180%)',
      WebkitBackdropFilter: 'blur(24px) saturate(180%)',
      border: '1.2px solid rgba(255,255,255,0.32)',
      boxShadow:
        'inset 0 1.5px 1px rgba(255,255,255,0.55), inset 0 -1px 2px rgba(255,255,255,0.14), 0 14px 34px rgba(0,0,0,0.4)',
      fontFamily: defaultTheme.fontSans,
    }}
  >
    {steps.map((step, idx) => {
      const isDone = idx < activeIndex;
      const isActive = idx === activeIndex;
      return (
        <React.Fragment key={step.id}>
          <div style={{display: 'flex', alignItems: 'center', gap: 8}}>
            <div
              style={{
                width: 20,
                height: 20,
                borderRadius: 999,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 12,
                fontWeight: 900,
                background: isDone ? '#22D3EE' : isActive ? 'rgba(34,211,238,0.22)' : 'rgba(255,255,255,0.08)',
                border: isActive ? '2px solid #22D3EE' : isDone ? 'none' : '1px solid rgba(255,255,255,0.2)',
                color: isDone ? '#050811' : '#22D3EE',
                boxShadow: isActive ? '0 0 10px rgba(34,211,238,0.75)' : 'none',
              }}
            >
              {isDone ? '✓' : isActive ? '•' : ''}
            </div>
            <span
              style={{
                fontSize: 16,
                fontWeight: isActive ? 800 : 600,
                color: isActive ? '#FFFFFF' : isDone ? '#22D3EE' : 'rgba(148,163,184,0.65)',
              }}
            >
              {step.label}
            </span>
          </div>
          {idx < steps.length - 1 ? (
            <div
              style={{
                width: 24,
                height: 1.5,
                background: isDone ? '#22D3EE' : 'rgba(255,255,255,0.16)',
              }}
            />
          ) : null}
        </React.Fragment>
      );
    })}
  </div>
);

export interface MacWindowStageProps {
  title: string;
  /** Relative path under `public/`, e.g. `library/demo.mp4` */
  videoSrc?: string;
  loopFrames?: number;
  playbackRate?: number;
  width?: number;
  height?: number;
  children?: React.ReactNode;
}

/** High-contrast light-chrome macOS window showcase for real product recordings or rebuilt web UIs. */
export const MacWindowStage: React.FC<MacWindowStageProps> = ({
  title,
  videoSrc,
  loopFrames,
  playbackRate = 1,
  width = 1360,
  height = 760,
  children,
}) => {
  const videoEl = videoSrc ? (
    <OffthreadVideo
      src={staticFile(videoSrc)}
      muted
      playbackRate={playbackRate}
      style={{width: '100%', height: '100%', objectFit: 'contain'}}
    />
  ) : null;

  return (
    <div
      style={{
        width,
        borderRadius: 18,
        overflow: 'hidden',
        background: '#F4F5F7',
        border: '1px solid rgba(255,255,255,0.22)',
        boxShadow: '0 36px 96px rgba(0,0,0,0.72)',
        fontFamily: defaultTheme.fontSans,
      }}
    >
      <div
        style={{
          height: 46,
          background: '#EBECEF',
          borderBottom: '1px solid rgba(0,0,0,0.08)',
          display: 'flex',
          alignItems: 'center',
          padding: '0 18px',
          position: 'relative',
        }}
      >
        <div style={{display: 'flex', gap: 8}}>
          <div style={{width: 12, height: 12, borderRadius: 999, background: '#FF5F56'}} />
          <div style={{width: 12, height: 12, borderRadius: 999, background: '#FFBD2E'}} />
          <div style={{width: 12, height: 12, borderRadius: 999, background: '#27C93F'}} />
        </div>
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            textAlign: 'center',
            fontFamily: defaultTheme.fontMono,
            fontSize: 16,
            fontWeight: 700,
            color: '#111827',
            pointerEvents: 'none',
          }}
        >
          {title}
        </div>
      </div>
      <div style={{position: 'relative', width: '100%', height, background: '#FFFFFF'}}>
        {videoEl ? (loopFrames ? <Loop durationInFrames={loopFrames}>{videoEl}</Loop> : videoEl) : null}
        {children}
      </div>
    </div>
  );
};
