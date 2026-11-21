// Long-lived chat agent for the assembly panel.
//
// Protocol: newline-delimited JSON on stdin/stdout.
//   in : {type:"init", baseURL, model, key, images, system}
//        {type:"prompt", id, text}
//        {type:"abort"}
//   out: {type:"ready"}
//        {type:"delta", text}
//        {type:"tool", name, detail}
//        {type:"tool_end", name, ok}
//        {type:"notice", text}
//        {type:"done", id, text}
//        {type:"error", message}
//
// Project reads and writes go through a Unix-domain socket owned by the app, so
// the agent never edits project.json directly. Context, tool-call loops, retries
// and compaction stay inside the Pi agent session.

import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {connect} from 'node:net';
import {createInterface} from 'node:readline';

const cwd = process.cwd();
const agentDir = await mkdtemp(join(tmpdir(), 'superworkspace-chat-'));
process.env.PI_CODING_AGENT_DIR = agentDir;
const provider = 'workspace';
let requestID = 0;
let secret = { value: '' };

const redact = (value) => {
  const text = String(value);
  return secret.value ? text.replaceAll(secret.value, '[redacted]') : text;
};

const out = (event) => process.stdout.write(`${JSON.stringify(event)}\n`);
const log = (message) => process.stderr.write(`${redact(message).slice(0, 1200)}\n`);

const bridgeCall = (tool, args) => new Promise((resolve) => {
  const socketPath = process.env.SW_BRIDGE_PATH;
  if (!socketPath) {
    resolve({ok: false, error: '项目通道未连接'});
    return;
  }
  const id = ++requestID;
  const socket = connect(socketPath);
  let buffer = '';
  let settled = false;
  const finish = (value) => {
    if (settled) return;
    settled = true;
    socket.destroy();
    resolve(value);
  };
  socket.setEncoding('utf8');
  socket.on('connect', () => socket.write(`${JSON.stringify({id, tool, args: args ?? {}})}\n`));
  socket.on('data', (chunk) => {
    buffer += chunk;
    const newline = buffer.indexOf('\n');
    if (newline < 0) return;
    try {
      const response = JSON.parse(buffer.slice(0, newline));
      finish({ok: Boolean(response.ok), result: response.result, error: response.error});
    } catch (error) {
      finish({ok: false, error: `项目通道返回了无法解析的内容：${error.message}`});
    }
  });
  socket.on('error', (error) => finish({ok: false, error: `项目通道错误：${error.message}`}));
  socket.setTimeout(130000, () => finish({ok: false, error: '项目操作超时'}));
});

let Type;
const clipArgument = () => Type.Union([Type.Number(), Type.String()], {
  description: '片段序号（1 开始）或片段 id',
});

const tool = (name, label, description, parameters, run) => ({
  name,
  label,
  description,
  parameters,
  execute: async (_callId, params) => {
    const response = await bridgeCall(name, params);
    const payload = response.ok
      ? (response.result ?? {ok: true})
      : {error: response.error || '操作失败'};
    return {
      content: [{type: 'text', text: JSON.stringify(payload)}],
      details: {},
      isError: !response.ok,
    };
  },
});

const buildTools = () => [
  tool('project_read', '读取项目', '读取当前项目的完整状态：片段顺序、裁剪、字幕、补充画面、素材库、动效状态与成片时间轴。修改前先调用它。', Type.Object({}), null),
  tool('clip_trim', '裁剪片段', '修改片段的入点和出点。时间单位是原视频秒数；只给一个边界时另一个保持。', Type.Object({
    clip: clipArgument(),
    start: Type.Optional(Type.Number({description: '新的入点（原视频秒数）'})),
    end: Type.Optional(Type.Number({description: '新的出点（原视频秒数）'})),
  })),
  tool('clip_split', '分割片段', '在原视频的 at 秒处把片段分成两段。', Type.Object({
    clip: clipArgument(),
    at: Type.Number({description: '分割点（原视频秒数）'}),
  })),
  tool('clip_move', '移动片段', '把片段移动到时间线的指定位置。position 从 1 开始，等于成片顺序。', Type.Object({
    clip: clipArgument(),
    position: Type.Number({description: '目标位置，1 开始'}),
  })),
  tool('clip_remove', '删除片段', '从项目中移除一个片段，可用撤销恢复。', Type.Object({clip: clipArgument()})),
  tool('clip_speed', '调整倍速', '设置片段的播放倍速（0.5 到 4.0，1.0 为原速）。若只想加速局部，先用 clip_split 切分后再对目标段调速。', Type.Object({
    clip: clipArgument(),
    speed: Type.Number({description: '播放倍速，范围 0.5 到 4.0'}),
  })),
  tool('clip_rename', '重命名片段', '给片段设置可读名称，便于识别。', Type.Object({
    clip: clipArgument(),
    title: Type.String({description: '片段名称，留空恢复默认编号'}),
  })),
  tool('subtitle_update', '修改字幕文字', '把某条字幕的文字改成 text。index 从 1 开始，与 project_read 返回的序号一致。', Type.Object({
    clip: clipArgument(),
    index: Type.Number({description: '字幕序号，1 开始'}),
    text: Type.String({description: '新的字幕文字'}),
  })),
  tool('subtitle_insert', '新增字幕', '在原视频的 at 秒处插入一条字幕。', Type.Object({
    clip: clipArgument(),
    at: Type.Number({description: '插入位置（原视频秒数）'}),
    text: Type.Optional(Type.String({description: '字幕文字'})),
  })),
  tool('subtitle_delete', '删除字幕', '删除一条字幕。', Type.Object({
    clip: clipArgument(),
    index: Type.Number({description: '字幕序号，1 开始'}),
  })),
  tool('subtitle_merge', '合并字幕', '把第 index 条与下一条合并。', Type.Object({
    clip: clipArgument(),
    index: Type.Number({description: '前一条字幕序号，1 开始'}),
  })),
  tool('subtitle_split', '分割字幕', '把第 index 条字幕在 at 秒处拆成两条。', Type.Object({
    clip: clipArgument(),
    index: Type.Number({description: '字幕序号，1 开始'}),
    at: Type.Number({description: '分割时间（原视频秒数）'}),
  })),
  tool('subtitle_move', '调整字幕时间', '修改一条字幕的起止时间，不能与相邻字幕重叠。', Type.Object({
    clip: clipArgument(),
    index: Type.Number({description: '字幕序号，1 开始'}),
    start: Type.Number({description: '新的开始时间（原视频秒数）'}),
    end: Type.Number({description: '新的结束时间（原视频秒数）'}),
  })),
  tool('canvas_set', '设置画幅', '设置项目画布尺寸；两个参数都省略表示自动。', Type.Object({
    width: Type.Optional(Type.Number({description: '宽度像素'})),
    height: Type.Optional(Type.Number({description: '高度像素'})),
  })),
  tool('insert_add', '添加补充画面', '用素材库中的图片或视频替换片段的一段画面，保留原声与字幕。时间是原视频秒数。', Type.Object({
    clip: clipArgument(),
    asset: Type.Union([Type.Number(), Type.String()], {description: '素材库序号（1 开始）或素材 id'}),
    start: Type.Number({description: '开始时间（原视频秒数）'}),
    end: Type.Number({description: '结束时间（原视频秒数）'}),
    assetStart: Type.Optional(Type.Number({description: '补充视频的起播时间，图片固定 0'})),
  })),
  tool('insert_update', '调整补充画面', '修改片段上已有补充画面的起止时间（原视频秒数）。', Type.Object({
    clip: clipArgument(),
    index: Type.Number({description: '补充画面序号，1 开始'}),
    start: Type.Optional(Type.Number({description: '新的开始时间（原视频秒数）'})),
    end: Type.Optional(Type.Number({description: '新的结束时间（原视频秒数）'})),
  })),
  tool('insert_remove', '移除补充画面', '移除片段上的一条补充画面。', Type.Object({
    clip: clipArgument(),
    index: Type.Number({description: '补充画面序号，1 开始'}),
  })),
  tool('audio_add', '添加音乐或音效', '把素材库中的音频素材铺到成片时间线（音乐自动淡入淡出并支持人声避让）。时间是成片秒数。', Type.Object({
    asset: Type.Union([Type.Number(), Type.String()], {description: '素材库音频序号（1 开始）或素材 id'}),
    kind: Type.Optional(Type.String({description: 'music（背景音乐，默认）或 effect（音效）'})),
    start: Type.Optional(Type.Number({description: '开始时间（成片秒数，默认 0）'})),
    end: Type.Optional(Type.Number({description: '结束时间（成片秒数，背景音乐默认铺满全片）'})),
    volume: Type.Optional(Type.Number({description: '音量 0–1.5，背景音乐默认 0.25，音效默认 0.85'})),
    fadeIn: Type.Optional(Type.Number({description: '淡入秒数'})),
    fadeOut: Type.Optional(Type.Number({description: '淡出秒数'})),
    duckUnderSpeech: Type.Optional(Type.Boolean({description: '人声说话时自动压低背景音乐音量，默认 true'})),
  })),
  tool('audio_update', '调整音乐或音效', '修改已有音频条的起止时间、音量、淡入淡出或人声避让。', Type.Object({
    index: Type.Optional(Type.Number({description: '音频条序号，1 开始'})),
    id: Type.Optional(Type.String({description: '音频条 id'})),
    start: Type.Optional(Type.Number({description: '新的开始时间（成片秒数）'})),
    end: Type.Optional(Type.Number({description: '新的结束时间（成片秒数）'})),
    volume: Type.Optional(Type.Number({description: '新的音量 0–1.5'})),
    fadeIn: Type.Optional(Type.Number({description: '淡入秒数'})),
    fadeOut: Type.Optional(Type.Number({description: '淡出秒数'})),
    duckUnderSpeech: Type.Optional(Type.Boolean({description: '是否开启人声避让'})),
  })),
  tool('audio_remove', '移除音乐或音效', '从时间线上删除一条背景音乐或音效。', Type.Object({
    index: Type.Optional(Type.Number({description: '音频条序号，1 开始'})),
    id: Type.Optional(Type.String({description: '音频条 id'})),
  })),
  tool('callout_add', '添加花字标注', '在成片画面上叠加花字、大标题、角标或下三分之一信息条。时间是成片秒数。', Type.Object({
    text: Type.String({description: '主文案'}),
    subtitle: Type.Optional(Type.String({description: '可选副标题'})),
    start: Type.Number({description: '开始时间（成片秒数）'}),
    end: Type.Optional(Type.Number({description: '结束时间（成片秒数，默认持续 3 秒）'})),
    style: Type.Optional(Type.String({description: 'title（大标题）、badge（角标）、callout（重点气泡，默认）、lowerThird（下三分之一信息条）'})),
    x: Type.Optional(Type.Number({description: '归一化横坐标 0–1，默认居中或靠左'})),
    y: Type.Optional(Type.Number({description: '归一化纵坐标 0–1（从顶部起算）'})),
    accentHex: Type.Optional(Type.String({description: '可选强调色十六进制，如 #F0713F'})),
  })),
  tool('callout_update', '调整花字标注', '修改已有花字的文案、样式、位置或起止时间。', Type.Object({
    index: Type.Optional(Type.Number({description: '花字序号，1 开始'})),
    id: Type.Optional(Type.String({description: '花字 id'})),
    text: Type.Optional(Type.String({description: '新的主文案'})),
    subtitle: Type.Optional(Type.String({description: '新的副标题'})),
    start: Type.Optional(Type.Number({description: '新的开始时间'})),
    end: Type.Optional(Type.Number({description: '新的结束时间'})),
    style: Type.Optional(Type.String({description: 'title / badge / callout / lowerThird'})),
    x: Type.Optional(Type.Number({description: '横坐标 0–1'})),
    y: Type.Optional(Type.Number({description: '纵坐标 0–1'})),
    accentHex: Type.Optional(Type.String({description: '强调色'})),
  })),
  tool('callout_remove', '移除花字标注', '从时间线上移除一条花字。', Type.Object({
    index: Type.Optional(Type.Number({description: '花字序号，1 开始'})),
    id: Type.Optional(Type.String({description: '花字 id'})),
  })),
  tool('silence_analyze', '分析静音停顿', '扫描片段的音频波形，返回所有长停顿/静音区间（原视频秒数），便于智能精剪去掉多余空白。', Type.Object({
    clip: clipArgument(),
    minDuration: Type.Optional(Type.Number({description: '最短静音秒数，默认 0.6'})),
    threshold: Type.Optional(Type.Number({description: '静音振幅阈值 0.005–0.2，默认 0.02'})),
  })),
  tool('motion_regenerate', '重做动效', '为整个片段重新生成 Remotion 动效。instruction 写清哪里不好看、想要什么效果，会并入该片段的剪辑说明。渲染在后台进行，需要几分钟到几十分钟。', Type.Object({
    clip: clipArgument(),
    instruction: Type.Optional(Type.String({description: '对动效的具体要求，例如「12–18 秒这一段不遮挡字幕，改成侧边卡片」'})),
  })),
  tool('job_status', '查询任务', '查看各片段的动效状态与进度。', Type.Object({})),
];

let session;
let busy = false;
let sawDelta = false;
let lastText = '';

const dispose = async (code = 0) => {
  session?.dispose();
  await rm(agentDir, {recursive: true, force: true});
  process.exit(code);
};

const setup = async (request) => {
  const {
    createAgentSession, createExtensionRuntime, ModelRuntime, SessionManager, SettingsManager,
  } = await import('@earendil-works/pi-coding-agent');
  const {Type: TypeBox} = await import('typebox');
  Type = TypeBox;
  const {InMemoryCredentialStore} = await import('@earendil-works/pi-ai');
  const modelRuntime = await ModelRuntime.create({
    credentials: new InMemoryCredentialStore(),
    modelsPath: null,
    modelsStorePath: join(agentDir, 'catalog.json'),
    refreshOnCreate: false,
  });
  modelRuntime.registerProvider(provider, {
    baseUrl: request.baseURL,
    api: 'openai-completions',
    models: [{
      id: request.model,
      name: request.model,
      reasoning: false,
      input: request.images ? ['text', 'image'] : ['text'],
      contextWindow: 262144,
      maxTokens: 16384,
      cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
    }],
  });
  await modelRuntime.setRuntimeApiKey(provider, request.key || 'local');
  secret.value = String(request.key ?? '');

  const resourceLoader = {
    getExtensions: () => ({extensions: [], errors: [], runtime: createExtensionRuntime()}),
    getSkills: () => ({skills: [], diagnostics: []}),
    getPrompts: () => ({prompts: [], diagnostics: []}),
    getThemes: () => ({themes: [], diagnostics: []}),
    getAgentsFiles: () => ({agentsFiles: []}),
    getSystemPrompt: () => undefined,
    getSystemPromptSource: () => undefined,
    getAppendSystemPrompt: () => [request.system],
    getAppendSystemPromptSources: () => [],
    extendResources: () => {},
    reload: async () => {},
  };

  const tools = buildTools();
  ({session} = await createAgentSession({
    cwd,
    agentDir,
    modelRuntime,
    model: modelRuntime.getModel(provider, request.model),
    thinkingLevel: 'off',
    resourceLoader,
    sessionManager: SessionManager.inMemory(cwd),
    settingsManager: SettingsManager.inMemory({
      compaction: {enabled: true},
      retry: {enabled: true, maxRetries: 3, baseDelayMs: 2000},
    }),
    tools: ['read', 'grep', 'find', 'ls', ...tools.map(({name}) => name)],
    customTools: tools,
  }));

  session.subscribe((event) => {
    if (event.type === 'message_update') {
      const delta = event.assistantMessageEvent;
      if (delta?.type === 'text_delta') {
        sawDelta = true;
        lastText += delta.delta;
        out({type: 'delta', text: delta.delta});
      }
      return;
    }
    if (event.type === 'tool_execution_start') {
      out({type: 'tool', name: event.toolName, detail: describe(event.args)});
      return;
    }
    if (event.type === 'tool_execution_end') {
      out({type: 'tool_end', name: event.toolName, ok: !event.isError});
      return;
    }
    if (event.type === 'auto_retry_start') {
      out({type: 'notice', text: `连接中断，${Math.round((event.delayMs ?? 2000) / 1000)} 秒后重试`});
      return;
    }
    if (event.type === 'agent_settled' && event.aborted) {
      out({type: 'error', message: '已停止。'});
    }
  });

  out({type: 'ready'});
};

const describe = (args) => {
  if (!args || typeof args !== 'object') return '';
  for (const key of ['clip', 'index', 'text', 'instruction', 'at', 'position']) {
    if (args[key] !== undefined) return String(args[key]).slice(0, 80);
  }
  return '';
};

const handlePrompt = async ({id, text}) => {
  if (!session) {
    out({type: 'error', message: 'AI 会话还没准备好。'});
    return;
  }
  if (busy) {
    out({type: 'error', message: '上一条还在处理，等它完成再发。'});
    return;
  }
  busy = true;
  sawDelta = false;
  lastText = '';
  try {
    await session.prompt(String(text));
    const message = session.messages.findLast((item) => item.role === 'assistant');
    const final = lastText.trim()
      || (message?.content ?? []).filter(({type}) => type === 'text').map(({text: value}) => value).join('\n').trim();
    out({type: 'done', id, text: final});
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    out({type: 'error', message: redact(message).slice(0, 600)});
  } finally {
    busy = false;
  }
};

const lines = createInterface({input: process.stdin, crlfDelay: Infinity});
lines.on('line', (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    out({type: 'error', message: `无法解析指令：${error.message}`});
    return;
  }
  if (message.type === 'init') {
    setup(message).catch((error) => {
      const text = error instanceof Error ? error.message : String(error);
      out({type: 'error', message: redact(text).slice(0, 800)});
    });
    return;
  }
  if (message.type === 'prompt') {
    void handlePrompt(message);
    return;
  }
  if (message.type === 'abort') {
    try { session?.abort(); } catch {}
    return;
  }
  if (message.type === 'shutdown') {
    void dispose(0);
  }
});

process.on('SIGTERM', () => void dispose(0));
process.on('SIGINT', () => void dispose(0));
