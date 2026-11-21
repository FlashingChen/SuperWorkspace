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
  name: 'studio-editorial-dark',
  bg: '#090d14',
  bgElevated: '#0f1622',
  surface: 'rgba(20, 28, 42, 0.92)',
  surfaceAlt: 'rgba(28, 39, 58, 0.92)',
  border: 'rgba(148, 163, 184, 0.22)',
  borderStrong: 'rgba(148, 163, 184, 0.42)',
  text: '#f1f5f9',
  textMuted: '#cbd5e1',
  textDim: '#94a3b8',
  cyan: '#5fe0dc',
  lime: '#a3e635',
  amber: '#fb923c',
  rose: '#fb7185',
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
