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
    if (s.matte != null && s.matte !== 'behindPerson' && s.matte !== 'personForeground') {
      errors.push(`shot ${s.id} has invalid matte mode: ${s.matte} (use "behindPerson" or "personForeground")`);
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
    if (o.matte != null && o.matte !== 'behindPerson' && o.matte !== 'personForeground') {
      errors.push(`overlay ${o.id} has invalid matte mode: ${o.matte} (use "behindPerson" or "personForeground")`);
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

function resolveSuperWorkspaceBin() {
  if (process.env.SUPERWORKSPACE_BIN && existsSync(process.env.SUPERWORKSPACE_BIN)) {
    return process.env.SUPERWORKSPACE_BIN;
  }
  const appBin = '/Applications/SuperWorkspace.app/Contents/MacOS/SuperWorkspace';
  if (existsSync(appBin)) return appBin;
  return null;
}

async function ensurePersonMatte(sourcePath, item) {
  const st = statSync(sourcePath);
  const hash = createHash('sha256')
    .update(JSON.stringify({size: st.size, mtimeMs: Math.round(st.mtimeMs), start: item.start, end: item.end}))
    .digest('hex')
    .slice(0, 12);
  const maskFile = join(CACHE_DIR, `matte-${safeFileToken(item.id)}-${hash}.mp4`);
  if (existsSync(maskFile) && statSync(maskFile).size > 0) {
    return maskFile;
  }
  const bin = resolveSuperWorkspaceBin();
  if (!bin) {
    throw new Error(`Person matting requested for ${item.id} (${item.matte}) but SUPERWORKSPACE_BIN is not available.`);
  }
  const tmpFile = join(CACHE_DIR, `matte-${safeFileToken(item.id)}-${hash}.tmp-${process.pid}.mp4`);
  try {
    await runCmd(bin, [
      'cli', 'matte',
      '--input', sourcePath,
      '--start', item.start.toFixed(4),
      '--end', item.end.toFixed(4),
      '--output', tmpFile,
      '--quality', 'balanced',
    ], {timeout: 600_000});
    renameSync(tmpFile, maskFile);
    return maskFile;
  } catch (err) {
    rmSync(tmpFile, {force: true});
    throw err;
  }
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
      if (width > 2400 && width % 4 === 0 && height % 4 === 0) {
        args.push('--scale', '0.5');
      }
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

  // On-demand Vision person matting ONLY for shots/overlays that declare `matte`.
  let mattedCount = 0;
  for (const s of resolvedShots) {
    if (s.matte === 'behindPerson' || s.matte === 'personForeground') {
      s.matteFile = await ensurePersonMatte(sourcePath, s);
      mattedCount++;
    }
  }
  for (const o of resolvedOverlays) {
    if (o.matte === 'behindPerson' || o.matte === 'personForeground') {
      o.matteFile = await ensurePersonMatte(sourcePath, o);
      mattedCount++;
    }
  }

  // Composite all cached shots + alpha overlays (+ optional matted person foregrounds) onto source.mp4 with hardware H.264.
  const orderedShots = [...resolvedShots].sort((a, b) => a.start - b.start);
  const inputs = ['-i', sourcePath];
  for (const s of orderedShots) {
    inputs.push('-i', s.cacheFile);
    if (s.matteFile) inputs.push('-i', s.matteFile);
  }
  for (const o of resolvedOverlays) {
    inputs.push('-i', o.cacheFile);
    if (o.matteFile) inputs.push('-i', o.matteFile);
  }

  const filterLines = [];
  let current = '0:v';
  let inputIndex = 1;

  function resolvePersonPose(item) {
    const scaleVal = typeof item.personScale === 'number' && Number.isFinite(item.personScale)
      ? Math.max(0.15, Math.min(1.0, item.personScale))
      : 1.0;
    const pw = Math.max(2, Math.round((width * scaleVal) / 2) * 2);
    const ph = Math.max(2, Math.round((height * scaleVal) / 2) * 2);
    const anchor = typeof item.personAnchor === 'string' ? item.personAnchor : 'bottomRight';
    let defaultX = 0;
    let defaultY = 0;
    if (scaleVal < 0.99) {
      if (anchor === 'bottomCenter') {
        defaultX = Math.max(0, Math.round((width - pw) / 2));
        defaultY = Math.max(0, height - ph);
      } else if (anchor === 'bottomLeft') {
        defaultX = 0;
        defaultY = Math.max(0, height - ph);
      } else if (anchor === 'topRight') {
        defaultX = Math.max(0, width - pw);
        defaultY = 0;
      } else {
        defaultX = Math.max(0, width - pw);
        defaultY = Math.max(0, height - ph);
      }
    }
    const px = typeof item.personX === 'number' && Number.isFinite(item.personX)
      ? Math.round(item.personX)
      : defaultX;
    const py = typeof item.personY === 'number' && Number.isFinite(item.personY)
      ? Math.round(item.personY)
      : defaultY;
    return {scale: scaleVal, w: pw, h: ph, x: px, y: py};
  }

  function appendPersonForeground(item, maskInputIdx, tag, {fromPose, toPose, enterDelay = 0, enterDur, exitDur, exitTail = 0}) {
    const startStr = item.start.toFixed(4);
    const endStr = item.end.toFixed(4);
    const dur = Math.max(0.05, item.end - item.start);
    const pose = resolvePersonPose(item);
    const srcSlice = `psrc_${tag}`;
    const maskSlice = `pmask_${tag}`;
    const merged = `pmer_${tag}`;
    const fg = `pfg_${tag}`;
    const next = `pmout_${tag}`;

    // Static full-screen or non-animated cutout (e.g. behindPerson)
    const isAnimated = item.matte === 'personForeground' && (enterDur > 0.01 || exitDur > 0.01 || enterDelay > 0.01 || exitTail > 0.01);
    if (!isAnimated) {
      filterLines.push(
        `[0:v]trim=start=${startStr}:end=${endStr},setpts=PTS-STARTPTS,format=rgba,scale=${pose.w}:${pose.h}[${srcSlice}]`,
      );
      filterLines.push(
        `[${maskInputIdx}:v]setpts=PTS-STARTPTS,format=gray,scale=${pose.w}:${pose.h},gblur=sigma=0.6[${maskSlice}]`,
      );
      filterLines.push(
        `[${srcSlice}][${maskSlice}]alphamerge,setpts=PTS-STARTPTS+${startStr}/TB[${fg}]`,
      );
      filterLines.push(
        `[${current}][${fg}]overlay=${pose.x}:${pose.y}:enable='between(t,${startStr},${endStr})':eof_action=pass[${next}]`,
      );
      current = next;
      return;
    }

    // Two-phase zero-ghosting transition on local time t (0..dur):
    //   1) Enter from real A-Roll: stage fades 0->1 over [0, enterFadeDur] while person stays locked at 1.0 (0,0),
    //      then person smoothly shrinks/glides over [enterFadeDur, enterFadeDur + moveDur] -> zero double-head ghosting!
    //   2) Adjacent personForeground glide (enterFadeDur == 0): person glides immediately over [0, enterDur].
    //   3) Exit back to real A-Roll: person smoothly grows back to 1.0 (0,0) over [dur - exitFadeDur - exitMoveDur, dur - exitFadeDur],
    //      then stage fades 1->0 over [dur - exitFadeDur, dur] while person stays locked at 1.0 (0,0).
    const eDelay = Math.min(enterDelay, dur * 0.2);
    const eMove = Math.min(enterDur, dur * 0.35);
    const eEnd = eDelay + eMove;
    const xTail = Math.min(exitTail, dur * 0.2);
    const xMove = Math.min(exitDur, dur * 0.35);
    const xStart = Math.max(eEnd, dur - xTail - xMove);

    const eDelayS = eDelay.toFixed(4);
    const eMoveS = Math.max(0.01, eMove).toFixed(4);
    const eEndS = eEnd.toFixed(4);
    const xStartS = xStart.toFixed(4);
    const xMoveS = Math.max(0.01, xMove).toFixed(4);

    const smooth = (u) => `((${u})*(${u})*(3-2*(${u})))`;
    const uEnter = eMove > 0.01 ? `clip((t-${eDelayS})/${eMoveS},0,1)` : '1';
    const uExit = xMove > 0.01 ? `clip((t-${xStartS})/${xMoveS},0,1)` : '0';
    const sEnter = eMove > 0.01 ? smooth(uEnter) : '1';
    const sExit = xMove > 0.01 ? smooth(uExit) : '0';

    const lerpExpr = (a, b, c) =>
      `if(lt(t,${eEndS}),${a}+(${b}-${a})*${sEnter},if(gt(t,${xStartS}),${b}+(${c}-${b})*${sExit},${b}))`;

    const wExpr = `max(2,trunc((${lerpExpr(fromPose.w, pose.w, toPose.w)})/2)*2)`;
    const hExpr = `max(2,trunc((${lerpExpr(fromPose.h, pose.h, toPose.h)})/2)*2)`;
    // overlay evaluates `t` in global timeline time, so shift t -> (t - start)
    const lt = `(t-${startStr})`;
    const ugEnter = eMove > 0.01 ? `clip((${lt}-${eDelayS})/${eMoveS},0,1)` : '1';
    const ugExit = xMove > 0.01 ? `clip((${lt}-${xStartS})/${xMoveS},0,1)` : '0';
    const gEnter = eMove > 0.01 ? smooth(ugEnter) : '1';
    const gExit = xMove > 0.01 ? smooth(ugExit) : '0';
    const gLerp = (a, b, c) =>
      `if(lt(${lt},${eEndS}),${a}+(${b}-${a})*${gEnter},if(gt(${lt},${xStartS}),${b}+(${c}-${b})*${gExit},${b}))`;
    const xExpr = gLerp(fromPose.x, pose.x, toPose.x);
    const yExpr = gLerp(fromPose.y, pose.y, toPose.y);

    // Alpha-merge at a crisp intermediate size, then dynamically scale frame-by-frame with smoothstep easing.
    const workW = Math.min(width, 1920);
    const workH = Math.max(2, Math.round((workW * height) / width / 2) * 2);
    filterLines.push(
      `[0:v]trim=start=${startStr}:end=${endStr},setpts=PTS-STARTPTS,format=rgba,scale=${workW}:${workH}[${srcSlice}]`,
    );
    filterLines.push(
      `[${maskInputIdx}:v]setpts=PTS-STARTPTS,format=gray,scale=${workW}:${workH},gblur=sigma=0.6[${maskSlice}]`,
    );
    filterLines.push(
      `[${srcSlice}][${maskSlice}]alphamerge[${merged}]`,
    );
    filterLines.push(
      `[${merged}]scale=w='${wExpr}':h='${hExpr}':eval=frame,setpts=PTS-STARTPTS+${startStr}/TB[${fg}]`,
    );
    filterLines.push(
      `[${current}][${fg}]overlay=x='${xExpr}':y='${yExpr}':enable='between(t,${startStr},${endStr})':eof_action=pass[${next}]`,
    );
    current = next;
  }

  const fullPose = {scale: 1.0, w: width, h: height, x: 0, y: 0};
  const sortedShots = [...resolvedShots].sort((a, b) => a.start - b.start);

  for (let i = 0; i < sortedShots.length; i++) {
    const s = sortedShots[i];
    const prev = i > 0 ? sortedShots[i - 1] : null;
    const nextShot = i + 1 < sortedShots.length ? sortedShots[i + 1] : null;
    const adjPrev = prev && prev.matte === 'personForeground' && Math.abs(s.start - prev.end) < 0.08;
    const adjNext = nextShot && nextShot.matte === 'personForeground' && Math.abs(nextShot.start - s.end) < 0.08;
    const tr = typeof s.personTransitionSeconds === 'number' && Number.isFinite(s.personTransitionSeconds)
      ? Math.max(0, Math.min(1.5, s.personTransitionSeconds))
      : 0.45;
    const dur = Math.max(0.05, s.end - s.start);
    const useEnterFade = s.matte === 'personForeground' && !adjPrev && tr > 0.01 && s.personEnter !== 'none';
    const useExitFade = s.matte === 'personForeground' && !adjNext && tr > 0.01 && s.personExit !== 'none';
    const enterFadeDur = useEnterFade ? Math.min(0.18, tr * 0.45, dur * 0.15) : 0;
    const exitFadeDur = useExitFade ? Math.min(0.18, tr * 0.45, dur * 0.15) : 0;
    const fadeInD = enterFadeDur.toFixed(4);
    const fadeOutD = exitFadeDur.toFixed(4);
    const fadeOutSt = Math.max(0, dur - exitFadeDur).toFixed(4);

    const shifted = `sv${i}`;
    const next = `b${i}`;
    let shotChain = `[${inputIndex}:v]scale=${width}:${height},format=rgba`;
    if (useEnterFade) shotChain += `,fade=t=in:st=0:d=${fadeInD}:alpha=1`;
    if (useExitFade) shotChain += `,fade=t=out:st=${fadeOutSt}:d=${fadeOutD}:alpha=1`;
    shotChain += `,setpts=PTS-STARTPTS+${s.start.toFixed(4)}/TB[${shifted}]`;
    filterLines.push(shotChain);
    filterLines.push(
      `[${current}][${shifted}]overlay=0:0:enable='between(t,${s.start.toFixed(4)},${s.end.toFixed(4)})':eof_action=pass[${next}]`,
    );
    current = next;
    inputIndex++;
    if (s.matteFile) {
      const fromPose = adjPrev ? resolvePersonPose(prev) : fullPose;
      const toPose = adjNext ? resolvePersonPose(s) : fullPose;
      appendPersonForeground(s, inputIndex, `s${i}`, {
        fromPose,
        toPose,
        enterDelay: enterFadeDur,
        enterDur: s.personEnter === 'none' ? 0 : tr,
        exitDur: (s.personExit === 'none' || adjNext) ? 0 : tr,
        exitTail: exitFadeDur,
      });
      inputIndex++;
    }
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
    if (o.matteFile) {
      appendPersonForeground(o, inputIndex, `o${i}`, {
        fromPose: fullPose,
        toPose: fullPose,
        enterDur: 0,
        exitDur: 0,
      });
      inputIndex++;
    }
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
    matted: mattedCount,
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
