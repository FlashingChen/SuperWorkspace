#!/usr/bin/env node
/**
 * SuperWorkspace host motion adapter (`sw-motion.mjs`).
 *
 * Bridges declarative `motion-manifest.json` + Remotion compositions with:
 *   - `validate`: manifest schema, bounds, timing, and subtitle safe-zone checks
 *   - `inspect`:  parallel keyframe preview + contact sheet stitching + blank/geometry audit
 *   - `render`:   content-hashed per-shot cache + bounded parallel Remotion render
 *                 + direct alpha overlay pipeline + hardware FFmpeg composition
 */

import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {join, relative, resolve} from 'node:path';
import {promisify} from 'node:util';

const execFileAsync = promisify(execFile);
const cwd = process.cwd();
const MANIFEST_PATH = join(cwd, 'motion-manifest.json');
const CACHE_DIR = join(cwd, '.sw-cache');
const INSPECT_DIR = join(cwd, 'out', 'inspect');
const SUBTITLE_SAFE_RATIO = 0.86;

function parseArgs(argv) {
  const cmd = argv[2] || 'validate';
  const opts = {};
  for (let i = 3; i < argv.length; i++) {
    const token = argv[i];
    if (token.startsWith('--')) {
      const key = token.slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith('--')) {
        opts[key] = next;
        i++;
      } else {
        opts[key] = true;
      }
    }
  }
  return {cmd, opts};
}

async function runCmd(bin, args, {timeout = 600_000} = {}) {
  const {stdout, stderr} = await execFileAsync(bin, args, {
    cwd,
    timeout,
    maxBuffer: 32 * 1024 * 1024,
    env: process.env,
  });
  return {stdout, stderr};
}

async function probeVideo(videoPath) {
  const {stdout} = await runCmd('ffprobe', [
    '-v', 'error',
    '-print_format', 'json',
    '-show_format',
    '-show_streams',
    videoPath,
  ], {timeout: 30_000});
  const info = JSON.parse(stdout);
  const vStream = (info.streams || []).find((s) => s.codec_type === 'video');
  const aStream = (info.streams || []).find((s) => s.codec_type === 'audio');
  if (!vStream) throw new Error(`No video stream found in ${videoPath}`);

  const parseRate = (raw) => {
    if (!raw || typeof raw !== 'string') return 60;
    const [n, d] = raw.split('/').map(Number);
    if (!Number.isFinite(n) || !Number.isFinite(d) || d <= 0) return 60;
    return n / d;
  };
  const fpsRaw = parseRate(vStream.r_frame_rate || vStream.avg_frame_rate);
  const fps = Math.max(24, Math.min(120, Math.round(fpsRaw)));
  const duration = Number(info.format?.duration || vStream.duration || 0);
  return {
    width: Number(vStream.width),
    height: Number(vStream.height),
    fps,
    duration,
    hasAudio: Boolean(aStream),
  };
}

function loadManifest() {
  if (!existsSync(MANIFEST_PATH)) {
    throw new Error('motion-manifest.json not found in workspace');
  }
  const raw = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8'));
  return {
    version: raw.version ?? 1,
    fps: raw.fps,
    width: raw.width,
    height: raw.height,
    shots: Array.isArray(raw.shots) ? raw.shots : [],
    overlays: Array.isArray(raw.overlays) ? raw.overlays : [],
  };
}

function validateManifest(manifest, sourceMeta) {
  const errors = [];
  const warnings = [];
  const width = manifest.width || sourceMeta?.width || 1920;
  const height = manifest.height || sourceMeta?.height || 1080;
  const duration = sourceMeta?.duration || Infinity;
  const seenIds = new Set();

  const sortedShots = [...manifest.shots].sort((a, b) => a.start - b.start);
  for (let i = 0; i < sortedShots.length; i++) {
    const s = sortedShots[i];
    if (!s.id || !s.composition) {
      errors.push(`shot[${i}] missing id or composition`);
      continue;
    }
    if (seenIds.has(s.id)) errors.push(`duplicate id: ${s.id}`);
    seenIds.add(s.id);
    if (!(typeof s.start === 'number' && typeof s.end === 'number' && s.end > s.start)) {
      errors.push(`shot ${s.id} has invalid range [${s.start}, ${s.end}]`);
    }
    if (s.start < -0.01 || s.end > duration + 0.15) {
      errors.push(`shot ${s.id} range [${s.start}, ${s.end}] exceeds source duration ${duration.toFixed(2)}s`);
    }
    if (i > 0 && s.start < sortedShots[i - 1].end - 0.02) {
      errors.push(`full-screen shots overlap: ${sortedShots[i - 1].id} and ${s.id}`);
    }
  }

  for (let i = 0; i < manifest.overlays.length; i++) {
    const o = manifest.overlays[i];
    if (!o.id || !o.composition) {
      errors.push(`overlay[${i}] missing id or composition`);
      continue;
    }
    if (seenIds.has(o.id)) errors.push(`duplicate id: ${o.id}`);
    seenIds.add(o.id);
    if (!(typeof o.start === 'number' && typeof o.end === 'number' && o.end > o.start)) {
      errors.push(`overlay ${o.id} has invalid range [${o.start}, ${o.end}]`);
    }
    if (o.start < -0.01 || o.end > duration + 0.15) {
      errors.push(`overlay ${o.id} range [${o.start}, ${o.end}] exceeds source duration ${duration.toFixed(2)}s`);
    }
    const ow = o.width ?? width;
    const oh = o.height ?? height;
    const ox = o.x ?? 0;
    const oy = o.y ?? 0;
    if (ow < 2 || oh < 2) errors.push(`overlay ${o.id} dimensions too small (${ow}x${oh})`);
    if (ox < 0 || oy < 0 || ox + ow > width + 2 || oy + oh > height + 2) {
      warnings.push(`overlay ${o.id} (${ox},${oy},${ow}x${oh}) extends past canvas ${width}x${height}`);
    }
    if (oy + oh > height * SUBTITLE_SAFE_RATIO && oy > height * 0.5) {
      warnings.push(
        `overlay ${o.id} bottom (${Math.round(oy + oh)}px) enters bottom subtitle safe zone (>${Math.round(height * SUBTITLE_SAFE_RATIO)}px)`,
      );
    }
  }

  return {ok: errors.length === 0, errors, warnings};
}

function collectSourceFiles(dir, acc = []) {
  if (!existsSync(dir)) return acc;
  for (const name of readdirSync(dir).sort()) {
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) {
      collectSourceFiles(full, acc);
    } else if (/\.(tsx?|jsx?|css|json)$/i.test(name)) {
      acc.push(full);
    }
  }
  return acc;
}

function safeFileToken(id) {
  return String(id || 'item').replace(/[^a-zA-Z0-9._-]+/g, '_');
}

function hashItem(item, kind, renderSpec) {
  const hash = createHash('sha256');
  hash.update(JSON.stringify({kind, item, renderSpec}));
  const files = new Set();
  for (const f of collectSourceFiles(join(cwd, 'src', 'sw-kit'))) files.add(f);
  if (Array.isArray(item.files) && item.files.length > 0) {
    for (const rel of item.files) {
      const full = resolve(cwd, rel);
      if (!existsSync(full)) continue;
      if (statSync(full).isDirectory()) {
        for (const nested of collectSourceFiles(full)) files.add(nested);
      } else {
        files.add(full);
      }
    }
  } else {
    for (const f of collectSourceFiles(join(cwd, 'src'))) files.add(f);
  }
  for (const f of [...files].sort()) {
    hash.update(relative(cwd, f));
    hash.update(readFileSync(f));
  }
  return hash.digest('hex').slice(0, 12);
}

async function runOptionalTypecheck() {
  const tscBin = join(cwd, 'node_modules', '.bin', 'tsc');
  if (!existsSync(tscBin)) return null;
  try {
    await runCmd(tscBin, ['--noEmit'], {timeout: 60_000});
    return null;
  } catch (err) {
    return (err.stdout || err.stderr || err.message || 'tsc --noEmit failed').trim();
  }
}

async function mapLimit(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  const runners = Array.from({length: Math.min(limit, items.length)}, async () => {
    while (next < items.length) {
      const idx = next++;
      results[idx] = await worker(items[idx], idx);
    }
  });
  await Promise.all(runners);
  return results;
}

async function checkImageVariance(imagePath) {
  try {
    const {stdout, stderr} = await runCmd('ffmpeg', [
      '-v', 'info',
      '-i', imagePath,
      '-vf', 'signalstats,metadata=print:file=-',
      '-f', 'null', '-',
    ], {timeout: 15_000});
    const combined = `${stdout}\n${stderr}`;
    const yavg = /YAVG=(\d+(?:\.\d+)?)/.exec(combined);
    const ymax = /YMAX=(\d+(?:\.\d+)?)/.exec(combined);
    const ymin = /YMIN=(\d+(?:\.\d+)?)/.exec(combined);
    if (yavg && ymax && ymin) {
      const spread = Number(ymax[1]) - Number(ymin[1]);
      if (spread < 3) {
        return `frame appears flat/blank (luma spread=${spread.toFixed(1)}, avg=${Number(yavg[1]).toFixed(1)})`;
      }
    }
  } catch {
    // Non-fatal diagnostic check
  }
  return null;
}

async function buildContactSheets(frameEntries, outDir) {
  if (frameEntries.length === 0) return [];
  const sheets = [];
  const perSheet = 6;
  for (let offset = 0; offset < frameEntries.length; offset += perSheet) {
    const batch = frameEntries.slice(offset, offset + perSheet);
    const cols = Math.min(3, batch.length);
    const sheetPath = join(outDir, `contact-sheet-${sheets.length + 1}.jpg`);
    const inputs = batch.flatMap((entry) => ['-i', entry.jpgPath || entry.path]);
    const filters = batch.map((_, idx) =>
      `[${idx}:v]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2:color=#0b1018[t${idx}]`,
    );
    const stackInputs = batch.map((_, idx) => `[t${idx}]`).join('');
    if (batch.length === 1) {
      filters.push('[t0]copy[out]');
    } else {
      filters.push(`${stackInputs}xstack=inputs=${batch.length}:layout=${buildGridLayout(batch.length, cols, 640, 360)}:fill=#0b1018[out]`);
    }
    await runCmd('ffmpeg', [
      '-y',
      ...inputs,
      '-filter_complex', filters.join(';'),
      '-map', '[out]',
      '-frames:v', '1',
      '-c:v', 'mjpeg',
      '-q:v', '4',
      sheetPath,
    ], {timeout: 60_000});
    sheets.push({
      path: sheetPath,
      frames: batch.map((b) => ({id: b.id, frame: b.frame, seconds: b.seconds})),
    });
  }
  return sheets;
}

function buildGridLayout(count, cols, w, h) {
  const coords = [];
  for (let i = 0; i < count; i++) {
    const col = i % cols;
    const row = Math.floor(i / cols);
    coords.push(`${col * w}_${row * h}`);
  }
  return coords.join('|');
}

async function cmdInspect(opts) {
  const sourcePath = join(cwd, 'source.mp4');
  const sourceMeta = existsSync(sourcePath) ? await probeVideo(sourcePath) : null;
  const manifest = loadManifest();
  const validation = validateManifest(manifest, sourceMeta);
  const fps = manifest.fps || sourceMeta?.fps || 60;
  const width = manifest.width || sourceMeta?.width || 1920;
  const scale = width > 1280 ? (1280 / width).toFixed(3) : '1';

  const filterIds = typeof opts.shots === 'string'
    ? new Set(opts.shots.split(',').map((s) => s.trim()).filter(Boolean))
    : null;

  const targets = [
    ...manifest.shots.map((s) => ({...s, kind: 'shot'})),
    ...manifest.overlays.map((o) => ({...o, kind: 'overlay'})),
  ].filter((item) => !filterIds || filterIds.has(item.id));

  mkdirSync(INSPECT_DIR, {recursive: true});
  const jobs = [];
  for (const item of targets) {
    const totalFrames = Math.max(1, Math.round((item.end - item.start) * fps));
    const sampleFrames = totalFrames <= 6
      ? [Math.floor(totalFrames / 2)]
      : [
          Math.max(1, Math.floor(totalFrames * 0.15)),
          Math.floor(totalFrames * 0.5),
          Math.max(1, Math.floor(totalFrames * 0.85)),
        ];
    for (const f of sampleFrames) {
      const token = `${safeFileToken(item.id)}-f${f}`;
      const isOverlay = item.kind === 'overlay';
      jobs.push({
        id: item.id,
        kind: item.kind,
        composition: item.composition,
        frame: f,
        seconds: Number((item.start + f / fps).toFixed(2)),
        path: join(INSPECT_DIR, isOverlay ? `${token}.png` : `${token}.jpg`),
        jpgPath: join(INSPECT_DIR, `${token}.jpg`),
        imageFormat: isOverlay ? 'png' : 'jpeg',
      });
    }
  }

  const warnings = [...validation.warnings];
  const errors = [...validation.errors];
  const tscErr = await runOptionalTypecheck();
  if (tscErr) errors.push(`TypeScript check failed:\n${tscErr}`);
  const renderedFrames = [];

  await mapLimit(jobs, 3, async (job) => {
    const args = [
      '--no-install', 'remotion', 'still',
      'src/index.ts',
      job.composition,
      job.path,
      '--frame', String(job.frame),
      '--scale', scale,
      '--image-format', job.imageFormat,
    ];
    try {
      await runCmd('npx', args, {timeout: 120_000});
      if (job.imageFormat === 'png' && job.jpgPath !== job.path) {
        // Bundled ffmpeg may not include PNG codecs; convert alpha overlay stills via macOS sips for contact sheet stitching.
        await runCmd('/usr/bin/sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '80', job.path, '--out', job.jpgPath], {timeout: 30_000});
      }
      renderedFrames.push(job);
      if (job.kind === 'shot') {
        const issue = await checkImageVariance(job.jpgPath);
        if (issue) warnings.push(`${job.id}@f${job.frame}: ${issue}`);
      }
    } catch (err) {
      errors.push(`still failed for ${job.id}@f${job.frame}: ${err.message}`);
    }
  });

  renderedFrames.sort((a, b) => a.seconds - b.seconds);
  const contactSheets = await buildContactSheets(renderedFrames, INSPECT_DIR);

  const report = {
    ok: errors.length === 0,
    errors,
    warnings,
    contactSheets,
    checkedFrames: renderedFrames.length,
  };
  writeFileSync(join(INSPECT_DIR, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  if (!report.ok) process.exitCode = 1;
}

async function cmdRender(opts) {
  const started = Date.now();
  const sourcePath = join(cwd, 'source.mp4');
  if (!existsSync(sourcePath)) {
    throw new Error('source.mp4 not found in workspace');
  }
  const sourceMeta = await probeVideo(sourcePath);
  const manifest = loadManifest();
  const validation = validateManifest(manifest, sourceMeta);
  if (!validation.ok) {
    console.error(JSON.stringify(validation, null, 2));
    process.exit(1);
  }

  const fps = manifest.fps || sourceMeta.fps || 60;
  const width = manifest.width || sourceMeta.width;
  const height = manifest.height || sourceMeta.height;
  const outputPath = resolve(cwd, typeof opts.output === 'string' ? opts.output : 'motion-pending.mp4');
  const concurrency = Math.max(1, Math.min(4, Number(opts.concurrency || 2)));

  mkdirSync(CACHE_DIR, {recursive: true});

  const renderSpec = {width, height, fps};
  const renderQueue = [];
  const resolvedShots = [];
  const resolvedOverlays = [];
  let cachedCount = 0;
  let renderedCount = 0;

  for (const shot of manifest.shots) {
    const hash = hashItem(shot, 'shot', renderSpec);
    const cacheFile = join(CACHE_DIR, `shot-${safeFileToken(shot.id)}-${hash}.mp4`);
    const entry = {...shot, cacheFile, hash};
    resolvedShots.push(entry);
    if (existsSync(cacheFile) && statSync(cacheFile).size > 0) {
      cachedCount++;
    } else {
      renderQueue.push({kind: 'shot', entry});
    }
  }

  for (const overlay of manifest.overlays) {
    const hash = hashItem(overlay, 'overlay', renderSpec);
    const cacheFile = join(CACHE_DIR, `overlay-${safeFileToken(overlay.id)}-${hash}.mov`);
    const entry = {...overlay, cacheFile, hash};
    resolvedOverlays.push(entry);
    if (existsSync(cacheFile) && statSync(cacheFile).size > 0) {
      cachedCount++;
    } else {
      renderQueue.push({kind: 'overlay', entry});
    }
  }

  await mapLimit(renderQueue, concurrency, async ({kind, entry}) => {
    const ext = kind === 'overlay' ? 'mov' : 'mp4';
    const tmpFile = join(
      CACHE_DIR,
      `${kind}-${safeFileToken(entry.id)}-${entry.hash}.tmp-${process.pid}-${Date.now()}.${ext}`,
    );
    const args = [
      '--no-install', 'remotion', 'render',
      'src/index.ts',
      entry.composition,
      tmpFile,
    ];
    if (kind === 'overlay') {
      args.push(
        '--codec', 'prores',
        '--prores-profile', '4444',
        '--image-format', 'png',
        '--pixel-format', 'yuva444p10le',
      );
    } else {
      args.push(
        '--codec', 'h264',
        '--pixel-format', 'yuv420p',
        '--crf', '18',
      );
    }
    try {
      await runCmd('npx', args, {timeout: 1_200_000});
      renameSync(tmpFile, entry.cacheFile);
      renderedCount++;
    } catch (err) {
      rmSync(tmpFile, {force: true});
      throw err;
    }
  });

  // Composite all cached shots + alpha overlays onto source.mp4 with hardware H.264.
  const inputs = ['-i', sourcePath];
  for (const s of resolvedShots) inputs.push('-i', s.cacheFile);
  for (const o of resolvedOverlays) inputs.push('-i', o.cacheFile);

  const filterLines = [];
  let current = '0:v';
  let inputIndex = 1;

  for (let i = 0; i < resolvedShots.length; i++) {
    const s = resolvedShots[i];
    const shifted = `sv${i}`;
    const next = `b${i}`;
    filterLines.push(
      `[${inputIndex}:v]scale=${width}:${height},setpts=PTS-STARTPTS+${s.start.toFixed(4)}/TB[${shifted}]`,
    );
    filterLines.push(
      `[${current}][${shifted}]overlay=0:0:enable='between(t,${s.start.toFixed(4)},${s.end.toFixed(4)})':eof_action=pass[${next}]`,
    );
    current = next;
    inputIndex++;
  }

  for (let i = 0; i < resolvedOverlays.length; i++) {
    const o = resolvedOverlays[i];
    const ox = Math.round(o.x ?? 0);
    const oy = Math.round(o.y ?? 0);
    const shifted = `ov${i}`;
    const next = `o${i}`;
    filterLines.push(
      `[${inputIndex}:v]setpts=PTS-STARTPTS+${o.start.toFixed(4)}/TB[${shifted}]`,
    );
    filterLines.push(
      `[${current}][${shifted}]overlay=${ox}:${oy}:enable='between(t,${o.start.toFixed(4)},${o.end.toFixed(4)})':eof_action=pass[${next}]`,
    );
    current = next;
    inputIndex++;
  }

  const baseArgs = ['-y', ...inputs];
  if (filterLines.length > 0) {
    baseArgs.push('-filter_complex', filterLines.join(';'), '-map', `[${current}]`);
  } else {
    baseArgs.push('-map', '0:v');
  }
  if (sourceMeta.hasAudio) {
    baseArgs.push('-map', '0:a', '-c:a', 'copy');
  }
  baseArgs.push('-r', String(fps), '-pix_fmt', 'yuv420p', '-movflags', '+faststart');

  const vtArgs = [...baseArgs, '-c:v', 'h264_videotoolbox', '-allow_sw', '1', '-q:v', '65', outputPath];
  try {
    await runCmd('ffmpeg', vtArgs, {timeout: 600_000});
  } catch {
    const swArgs = [...baseArgs, '-c:v', 'libx264', '-crf', '18', '-preset', 'fast', outputPath];
    await runCmd('ffmpeg', swArgs, {timeout: 600_000});
  }

  const summary = {
    ok: true,
    output: outputPath,
    fps,
    width,
    height,
    rendered: renderedCount,
    cached: cachedCount,
    elapsedSeconds: Number(((Date.now() - started) / 1000).toFixed(1)),
  };
  console.log(JSON.stringify(summary, null, 2));
}

async function main() {
  const {cmd, opts} = parseArgs(process.argv);
  if (cmd === 'validate') {
    const sourcePath = join(cwd, 'source.mp4');
    const sourceMeta = existsSync(sourcePath) ? await probeVideo(sourcePath) : null;
    const manifest = loadManifest();
    const res = validateManifest(manifest, sourceMeta);
    console.log(JSON.stringify({...res, sourceMeta}, null, 2));
    if (!res.ok) process.exitCode = 1;
  } else if (cmd === 'inspect') {
    await cmdInspect(opts);
  } else if (cmd === 'render') {
    await cmdRender(opts);
  } else {
    throw new Error(`Unknown command: ${cmd}. Use validate | inspect | render.`);
  }
}

main().catch((err) => {
  console.error(JSON.stringify({ok: false, error: err?.message || String(err)}));
  process.exit(1);
});
