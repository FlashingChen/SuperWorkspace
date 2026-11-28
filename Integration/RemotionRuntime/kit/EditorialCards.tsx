import React from 'react';
import {Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {defaultTheme} from './theme';

const SPRING_SNAPPY = {damping: 18, stiffness: 210, mass: 0.7};

// ---------------------------------------------------------------------------
// 1. BrandDeckCard — Crisp pure-white physical card for official brand logos
// ---------------------------------------------------------------------------

export interface BrandDeckCardProps {
  /** Brand or product name shown cleanly below the official logo. */
  name: string;
  /** Path under `public/` (e.g. `assets/logos/claude-color.svg`). Never hand-draw brand SVGs. */
  logoSrc?: string;
  /** Optional compact category tag at the bottom (e.g. "Agent", "LLM", "Cloud"). */
  category?: string;
  /** Optional subtle accent for the category tag. */
  categoryColor?: string;
  width?: number;
  height?: number;
  startFrame?: number;
  dimmed?: boolean;
  highlighted?: boolean;
}

export const BrandDeckCard: React.FC<BrandDeckCardProps> = ({
  name,
  logoSrc,
  category,
  categoryColor = '#0284C7',
  width = 168,
  height = 208,
  startFrame = 0,
  dimmed = false,
  highlighted = false,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  if (frame < startFrame) return null;

  const p = spring({frame: frame - startFrame, fps, config: SPRING_SNAPPY});
  const monogram = name.trim().slice(0, 2).toUpperCase();

  return (
    <div
      style={{
        width,
        height,
        borderRadius: 16,
        background: '#FFFFFF',
        border: highlighted ? '2px solid #0EA5E9' : '1px solid rgba(15, 23, 42, 0.08)',
        boxShadow: highlighted
          ? '0 20px 44px rgba(0, 0, 0, 0.48), 0 0 0 3px rgba(14, 165, 233, 0.25)'
          : '0 14px 32px rgba(0, 0, 0, 0.42)',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '22px 14px 16px',
        boxSizing: 'border-box',
        fontFamily: defaultTheme.fontSans,
        opacity: (dimmed ? 0.34 : 1) * p,
        transform: `translateY(${interpolate(p, [0, 1], [18, 0])}px) scale(${interpolate(p, [0, 1], [0.92, 1])})`,
      }}
    >
      <div
        style={{
          width: 64,
          height: 64,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        {logoSrc ? (
          <Img
            src={staticFile(logoSrc)}
            style={{width: 56, height: 56, objectFit: 'contain'}}
          />
        ) : (
          <div
            style={{
              width: 52,
              height: 52,
              borderRadius: 12,
              background: '#0F172A',
              color: '#F8FAFC',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 20,
              fontWeight: 800,
              letterSpacing: '0.02em',
            }}
          >
            {monogram}
          </div>
        )}
      </div>

      <div
        style={{
          fontSize: 20,
          fontWeight: 800,
          color: '#0F172A',
          letterSpacing: '-0.01em',
          textAlign: 'center',
          lineHeight: 1.15,
        }}
      >
        {name}
      </div>

      {category ? (
        <div
          style={{
            padding: '4px 12px',
            borderRadius: 6,
            background: `${categoryColor}16`,
            color: categoryColor,
            fontSize: 13,
            fontWeight: 700,
            letterSpacing: '0.02em',
          }}
        >
          {category}
        </div>
      ) : (
        <div style={{height: 22}} />
      )}
    </div>
  );
};

// ---------------------------------------------------------------------------
// 2. EditorialRankCard — Matte physical side card (crimson / obsidian / paper)
// ---------------------------------------------------------------------------

export type EditorialCardVariant = 'crimson' | 'obsidian' | 'paper';

export interface EditorialRankCardProps {
  title: string;
  subtitle?: string;
  badge?: string;
  /** Path under `public/` (e.g. `assets/logos/claude-color.svg`). */
  logoSrc?: string;
  points: string[];
  footnote?: string;
  variant?: EditorialCardVariant;
  width?: number;
  startFrame?: number;
}

const RANK_PALETTE: Record<
  EditorialCardVariant,
  {
    bg: string;
    border: string;
    title: string;
    subtitle: string;
    body: string;
    divider: string;
    badgeBg: string;
    badgeText: string;
  }
> = {
  crimson: {
    bg: 'linear-gradient(165deg, #C81E1E 0%, #991B1B 100%)',
    border: 'rgba(255, 255, 255, 0.22)',
    title: '#FFFFFF',
    subtitle: 'rgba(255, 255, 255, 0.78)',
    body: '#FFFFFF',
    divider: 'rgba(255, 255, 255, 0.22)',
    badgeBg: 'rgba(255, 255, 255, 0.16)',
    badgeText: '#FFFFFF',
  },
  obsidian: {
    bg: 'linear-gradient(165deg, #171B24 0%, #0E1016 100%)',
    border: 'rgba(255, 255, 255, 0.16)',
    title: '#F8FAFC',
    subtitle: 'rgba(203, 213, 225, 0.72)',
    body: '#E2E8F0',
    divider: 'rgba(255, 255, 255, 0.12)',
    badgeBg: 'rgba(255, 255, 255, 0.10)',
    badgeText: '#F8FAFC',
  },
  paper: {
    bg: '#F4F4F0',
    border: 'rgba(15, 23, 42, 0.12)',
    title: '#0F172A',
    subtitle: '#475569',
    body: '#1E293B',
    divider: 'rgba(15, 23, 42, 0.10)',
    badgeBg: '#0F172A',
    badgeText: '#F8FAFC',
  },
};

export const EditorialRankCard: React.FC<EditorialRankCardProps> = ({
  title,
  subtitle,
  badge,
  logoSrc,
  points,
  footnote,
  variant = 'obsidian',
  width = 320,
  startFrame = 0,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  if (frame < startFrame) return null;

  const p = spring({frame: frame - startFrame, fps, config: SPRING_SNAPPY});
  const colors = RANK_PALETTE[variant];

  return (
    <div
      style={{
        width,
        borderRadius: 16,
        background: colors.bg,
        border: `1.5px solid ${colors.border}`,
        boxShadow: '0 18px 42px rgba(0, 0, 0, 0.48)',
        padding: '22px 24px',
        boxSizing: 'border-box',
        fontFamily: defaultTheme.fontSans,
        opacity: p,
        transform: `translateY(${interpolate(p, [0, 1], [16, 0])}px) scale(${interpolate(p, [0, 1], [0.95, 1])})`,
      }}
    >
      <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12}}>
        {logoSrc ? (
          <div
            style={{
              width: 44,
              height: 44,
              borderRadius: 10,
              background: '#FFFFFF',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              flexShrink: 0,
            }}
          >
            <Img src={staticFile(logoSrc)} style={{width: 30, height: 30, objectFit: 'contain'}} />
          </div>
        ) : (
          <div />
        )}
        {badge ? (
          <div
            style={{
              padding: '5px 12px',
              borderRadius: 6,
              background: colors.badgeBg,
              color: colors.badgeText,
              fontSize: 15,
              fontWeight: 800,
              letterSpacing: '0.04em',
            }}
          >
            {badge}
          </div>
        ) : null}
      </div>

      <div style={{marginTop: logoSrc || badge ? 16 : 0}}>
        <div style={{fontSize: 30, fontWeight: 900, color: colors.title, lineHeight: 1.12, letterSpacing: '-0.02em'}}>
          {title}
        </div>
        {subtitle ? (
          <div style={{marginTop: 4, fontSize: 15, fontWeight: 600, color: colors.subtitle}}>{subtitle}</div>
        ) : null}
      </div>

      <div style={{height: 1, background: colors.divider, margin: '18px 0 16px'}} />

      <div style={{display: 'flex', flexDirection: 'column', gap: 10}}>
        {points.map((point, index) => (
          <div
            key={index}
            style={{
              fontSize: 20,
              fontWeight: 700,
              color: colors.body,
              lineHeight: 1.35,
            }}
          >
            {point}
          </div>
        ))}
      </div>

      {footnote ? (
        <div
          style={{
            marginTop: 18,
            fontSize: 11,
            fontWeight: 600,
            fontFamily: defaultTheme.fontMono,
            color: colors.subtitle,
            letterSpacing: '0.08em',
            textTransform: 'uppercase',
          }}
        >
          {footnote}
        </div>
      ) : null}
    </div>
  );
};

// ---------------------------------------------------------------------------
// 3. DataRuleList — Hairline editorial data rows with verified source footer
// ---------------------------------------------------------------------------

export interface DataRuleRow {
  label: string;
  valueText: string;
  /** 0..1 bar fill ratio. */
  ratio: number;
  accent?: string;
}

export interface DataRuleListProps {
  title: string;
  accentLabel?: string;
  rows: DataRuleRow[];
  /** Mandatory verified provenance (e.g. "ARTIFICIAL ANALYSIS · NOV 22"). */
  source: string;
  width?: number;
  startFrame?: number;
}

export const DataRuleList: React.FC<DataRuleListProps> = ({
  title,
  accentLabel,
  rows,
  source,
  width = 400,
  startFrame = 0,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  if (frame < startFrame) return null;

  const p = spring({frame: frame - startFrame, fps, config: SPRING_SNAPPY});

  return (
    <div
      style={{
        width,
        padding: '18px 20px 14px',
        borderRadius: 12,
        background: 'rgba(10, 12, 18, 0.84)',
        border: '1px solid rgba(255, 255, 255, 0.14)',
        boxShadow: '0 14px 34px rgba(0, 0, 0, 0.42)',
        fontFamily: defaultTheme.fontSans,
        opacity: p,
        transform: `translateY(${interpolate(p, [0, 1], [12, 0])}px)`,
      }}
    >
      <div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 14}}>
        <span style={{fontSize: 18, fontWeight: 800, color: '#F8FAFC', letterSpacing: '0.01em'}}>{title}</span>
        {accentLabel ? (
          <span
            style={{
              fontSize: 15,
              fontWeight: 700,
              color: '#FBBF24',
              fontVariantNumeric: 'tabular-nums',
            }}
          >
            {accentLabel}
          </span>
        ) : null}
      </div>

      <div style={{display: 'flex', flexDirection: 'column', gap: 12}}>
        {rows.map((row, idx) => {
          const rowP = spring({
            frame: Math.max(0, frame - startFrame - idx * 6),
            fps,
            config: {damping: 20, stiffness: 160, mass: 0.8},
          });
          const fill = Math.max(0, Math.min(1, row.ratio)) * rowP;
          const barColor = row.accent ?? '#38BDF8';
          return (
            <div key={idx}>
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'baseline',
                  marginBottom: 6,
                }}
              >
                <span style={{fontSize: 15, fontWeight: 600, color: '#CBD5E1'}}>{row.label}</span>
                <span
                  style={{
                    fontSize: 16,
                    fontWeight: 800,
                    color: '#FFFFFF',
                    fontVariantNumeric: 'tabular-nums',
                    fontFamily: defaultTheme.fontMono,
                  }}
                >
                  {row.valueText}
                </span>
              </div>
              <div style={{height: 3, width: '100%', background: 'rgba(255, 255, 255, 0.12)', borderRadius: 2}}>
                <div
                  style={{
                    height: '100%',
                    width: `${fill * 100}%`,
                    background: barColor,
                    borderRadius: 2,
                  }}
                />
              </div>
            </div>
          );
        })}
      </div>

      <div
        style={{
          marginTop: 14,
          paddingTop: 10,
          borderTop: '1px solid rgba(255, 255, 255, 0.10)',
          fontSize: 11,
          fontWeight: 600,
          fontFamily: defaultTheme.fontMono,
          color: 'rgba(203, 213, 225, 0.56)',
          letterSpacing: '0.08em',
          textTransform: 'uppercase',
        }}
      >
        {source}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// 4. QuoteEvidenceCard — Real transcript / post / doc excerpt with highlights
// ---------------------------------------------------------------------------

export interface QuoteEvidenceLine {
  text: string;
  highlight?: boolean;
  tag?: string;
}

export interface QuoteEvidenceCardProps {
  header: string;
  subHeader?: string;
  lines: QuoteEvidenceLine[];
  source: string;
  width?: number;
  startFrame?: number;
}

export const QuoteEvidenceCard: React.FC<QuoteEvidenceCardProps> = ({
  header,
  subHeader,
  lines,
  source,
  width = 620,
  startFrame = 0,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  if (frame < startFrame) return null;

  const p = spring({frame: frame - startFrame, fps, config: SPRING_SNAPPY});

  return (
    <div
      style={{
        width,
        borderRadius: 14,
        background: '#FAF9F5',
        border: '1px solid rgba(15, 23, 42, 0.12)',
        boxShadow: '0 20px 48px rgba(0, 0, 0, 0.45)',
        padding: '22px 26px 18px',
        boxSizing: 'border-box',
        fontFamily: defaultTheme.fontSans,
        opacity: p,
        transform: `translateY(${interpolate(p, [0, 1], [16, 0])}px)`,
      }}
    >
      <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 14}}>
        <span style={{fontSize: 17, fontWeight: 800, color: '#0F172A'}}>{header}</span>
        {subHeader ? (
          <span style={{fontSize: 13, fontWeight: 600, color: '#64748B', fontFamily: defaultTheme.fontMono}}>
            {subHeader}
          </span>
        ) : null}
      </div>

      <div style={{height: 1, background: 'rgba(15, 23, 42, 0.10)', marginBottom: 16}} />

      <div style={{display: 'flex', flexDirection: 'column', gap: 10}}>
        {lines.map((line, idx) => (
          <div key={idx} style={{display: 'flex', alignItems: 'flex-start', gap: 10}}>
            <div style={{flex: 1, fontSize: 18, fontWeight: 600, color: '#1E293B', lineHeight: 1.5}}>
              {line.highlight ? (
                <span
                  style={{
                    background: '#FDE047',
                    color: '#0F172A',
                    padding: '2px 6px',
                    borderRadius: 4,
                  }}
                >
                  {line.text}
                </span>
              ) : (
                line.text
              )}
            </div>
            {line.tag ? (
              <span
                style={{
                  flexShrink: 0,
                  padding: '3px 9px',
                  borderRadius: 4,
                  background: '#DC2626',
                  color: '#FFFFFF',
                  fontSize: 13,
                  fontWeight: 800,
                }}
              >
                {line.tag}
              </span>
            ) : null}
          </div>
        ))}
      </div>

      <div
        style={{
          marginTop: 16,
          paddingTop: 10,
          borderTop: '1px solid rgba(15, 23, 42, 0.08)',
          fontSize: 11,
          fontWeight: 700,
          fontFamily: defaultTheme.fontMono,
          color: '#64748B',
          letterSpacing: '0.08em',
          textTransform: 'uppercase',
        }}
      >
        {source}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// 5. QuadrantPlot — Minimalist 2D positioning / tradeoff diagram with real logos
// ---------------------------------------------------------------------------

export interface QuadrantNode {
  id: string;
  label: string;
  /** Path under `public/` (e.g. `assets/logos/openai.svg`). */
  logoSrc?: string;
  /** Normalized 0..1 left-to-right. */
  x: number;
  /** Normalized 0..1 bottom-to-top. */
  y: number;
  note?: string;
  noteColor?: string;
  startFrame?: number;
}

export interface QuadrantPlotProps {
  xLabel: string;
  yLabel: string;
  nodes: QuadrantNode[];
  source?: string;
  width?: number;
  height?: number;
  startFrame?: number;
}

export const QuadrantPlot: React.FC<QuadrantPlotProps> = ({
  xLabel,
  yLabel,
  nodes,
  source,
  width = 960,
  height = 560,
  startFrame = 0,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  if (frame < startFrame) return null;

  const axisP = spring({frame: frame - startFrame, fps, config: {damping: 22, stiffness: 140}});
  const padLeft = 72;
  const padRight = 64;
  const padTop = 52;
  const padBottom = 64;
  const plotW = width - padLeft - padRight;
  const plotH = height - padTop - padBottom;

  return (
    <div style={{position: 'relative', width, height, fontFamily: defaultTheme.fontSans}}>
      <svg width={width} height={height} style={{position: 'absolute', inset: 0, overflow: 'visible'}}>
        {/* Y axis */}
        <line
          x1={padLeft}
          y1={padTop + plotH}
          x2={padLeft}
          y2={padTop + plotH * (1 - axisP)}
          stroke="rgba(255, 255, 255, 0.52)"
          strokeWidth={2}
        />
        {/* X axis */}
        <line
          x1={padLeft}
          y1={padTop + plotH}
          x2={padLeft + plotW * axisP}
          y2={padTop + plotH}
          stroke="rgba(255, 255, 255, 0.52)"
          strokeWidth={2}
        />
        {/* Subtle dashed mid-guides */}
        <line
          x1={padLeft + plotW * 0.5}
          y1={padTop}
          x2={padLeft + plotW * 0.5}
          y2={padTop + plotH}
          stroke="rgba(255, 255, 255, 0.10)"
          strokeDasharray="6 6"
          strokeWidth={1}
        />
        <line
          x1={padLeft}
          y1={padTop + plotH * 0.5}
          x2={padLeft + plotW}
          y2={padTop + plotH * 0.5}
          stroke="rgba(255, 255, 255, 0.10)"
          strokeDasharray="6 6"
          strokeWidth={1}
        />
      </svg>

      {/* Axis labels */}
      <div
        style={{
          position: 'absolute',
          left: padLeft + 14,
          top: padTop - 6,
          fontSize: 16,
          fontWeight: 700,
          color: 'rgba(248, 250, 252, 0.78)',
        }}
      >
        ↑ {yLabel}
      </div>
      <div
        style={{
          position: 'absolute',
          right: padRight,
          bottom: padBottom - 36,
          fontSize: 16,
          fontWeight: 700,
          color: 'rgba(248, 250, 252, 0.78)',
        }}
      >
        {xLabel} →
      </div>

      {/* Nodes */}
      {nodes.map((node, idx) => {
        const nodeStart = node.startFrame ?? startFrame + 10 + idx * 8;
        if (frame < nodeStart) return null;
        const np = spring({frame: frame - nodeStart, fps, config: SPRING_SNAPPY});
        const px = padLeft + Math.max(0.05, Math.min(0.95, node.x)) * plotW;
        const py = padTop + (1 - Math.max(0.05, Math.min(0.95, node.y))) * plotH;
        return (
          <div
            key={node.id}
            style={{
              position: 'absolute',
              left: px,
              top: py,
              transform: `translate(-50%, -50%) scale(${interpolate(np, [0, 1], [0.75, 1])})`,
              opacity: np,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 6,
            }}
          >
            <div
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 10,
                padding: '10px 16px',
                borderRadius: 12,
                background: '#FFFFFF',
                boxShadow: '0 12px 28px rgba(0, 0, 0, 0.45)',
              }}
            >
              {node.logoSrc ? (
                <Img src={staticFile(node.logoSrc)} style={{width: 26, height: 26, objectFit: 'contain'}} />
              ) : null}
              <span style={{fontSize: 18, fontWeight: 800, color: '#0F172A', whiteSpace: 'nowrap'}}>{node.label}</span>
            </div>
            {node.note ? (
              <div
                style={{
                  padding: '3px 10px',
                  borderRadius: 6,
                  background: node.noteColor ?? '#DC2626',
                  color: '#FFFFFF',
                  fontSize: 13,
                  fontWeight: 700,
                  whiteSpace: 'nowrap',
                }}
              >
                {node.note}
              </div>
            ) : null}
          </div>
        );
      })}

      {source ? (
        <div
          style={{
            position: 'absolute',
            left: padLeft,
            bottom: 8,
            fontSize: 11,
            fontWeight: 600,
            fontFamily: defaultTheme.fontMono,
            color: 'rgba(203, 213, 225, 0.5)',
            letterSpacing: '0.08em',
            textTransform: 'uppercase',
          }}
        >
          {source}
        </div>
      ) : null}
    </div>
  );
};
