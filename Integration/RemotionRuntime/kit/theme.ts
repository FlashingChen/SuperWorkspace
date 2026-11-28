export interface MotionTheme {
  readonly name: string;
  readonly bg: string;
  readonly bgElevated: string;
  readonly surface: string;
  readonly surfaceAlt: string;
  readonly border: string;
  readonly borderStrong: string;
  readonly text: string;
  readonly textMuted: string;
  readonly textDim: string;
  readonly cyan: string;
  readonly lime: string;
  readonly amber: string;
  readonly rose: string;
  readonly fontSans: string;
  readonly fontMono: string;
}

export const defaultTheme: MotionTheme = {
  name: 'obsidian-editorial-dark',
  bg: '#0a0c12',
  bgElevated: '#111520',
  surface: 'rgba(18, 22, 33, 0.94)',
  surfaceAlt: 'rgba(26, 32, 48, 0.94)',
  border: 'rgba(255, 255, 255, 0.12)',
  borderStrong: 'rgba(255, 255, 255, 0.28)',
  text: '#f8fafc',
  textMuted: '#cbd5e1',
  textDim: '#64748b',
  cyan: '#38bdf8',
  lime: '#34d399',
  amber: '#fbbf24',
  rose: '#f87171',
  fontSans:
    '-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Noto Sans SC", "Inter", sans-serif',
  fontMono:
    '"JetBrains Mono", "SF Mono", Menlo, Monaco, Consolas, monospace',
};

export function createTheme(overrides: Partial<MotionTheme> = {}): MotionTheme {
  return {...defaultTheme, ...overrides};
}

/** Reserved layout proportions (fraction of canvas height) so world content avoids fixed HUD and captions. */
export const SAFE_ZONES = {
  topHeaderRatio: 0.12,
  bottomSubtitleRatio: 0.14,
  sideMarginRatio: 0.05,
} as const;
