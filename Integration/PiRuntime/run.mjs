import {mkdtemp, rm} from 'node:fs/promises';
import {readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const request = JSON.parse(readFileSync(0, 'utf8'));
const cwd = process.cwd();
const agentDir = await mkdtemp(join(tmpdir(), 'superworkspace-pi-'));
process.env.PI_CODING_AGENT_DIR = agentDir;
const provider = 'workspace';
const startedAt = Date.now();

// Progress goes to stderr only: stdout is reserved for the final assistant text.
const progress = (event) => {
  let line = `SW_PROGRESS ${JSON.stringify({...event, at: Date.now()})}`;
  if (request.key) line = line.replaceAll(request.key, '[redacted]');
  process.stderr.write(line + '\n');
};
const number = (value, fallback) => typeof value === 'number' && Number.isFinite(value) && value >= 0
  ? value
  : fallback;
const retry = {
  enabled: true,
  maxRetries: 3,
  baseDelayMs: 2000,
  ...(request.retry && typeof request.retry === 'object' ? request.retry : {}),
};
const budgetMinutes = number(request.budgetMinutes, 30);
const budgetToolCalls = number(request.budgetToolCalls, 100);
// Leave time to render and deliver instead of aborting: nudge the agent to wrap up first.
const wrapUpRatio = Math.min(0.95, Math.max(0.5, number(request.wrapUpRatio, 0.9)));

const describeToolArgs = (args) => {
  const compress = (value) => value.replace(/\s+/g, ' ').trim().slice(0, 120);
  if (typeof args === 'string') return compress(args);
  if (!args || typeof args !== 'object') return '';
  for (const key of ['command', 'path', 'file_path', 'pattern', 'query', 'url', 'description']) {
    if (typeof args[key] === 'string') return compress(args[key]);
  }
  return compress(Object.keys(args).join(', '));
};

let session;
let toolCalls = 0;
let turns = 0;
let budget;
const toolNumbers = new Map();
const hitBudget = (reason, limit) => {
  if (budget) return;
  budget = {reason, limit};
  progress({type: 'budget', reason, limit});
  void session?.abort();
};
const abort = () => void session?.abort();

try {
  const {
    createAgentSession, createExtensionRuntime, ModelRuntime, SessionManager, SettingsManager,
    discoverAndLoadExtensions,
  } = await import('@earendil-works/pi-coding-agent');
  const {Type} = await import('typebox');
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
      // Reasoning models can spend an entire small budget on thinking and return no text.
      maxTokens: request.tools ? 32768 : 16384,
      cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
    }],
  });
  // The key stays in process memory. Pi's bash tools never inherit it.
  await modelRuntime.setRuntimeApiKey(provider, request.key || 'local');

  const resourceLoader = {
    getExtensions: () => loadedExtensions ?? {extensions: [], errors: [], runtime: createExtensionRuntime()},
    getSkills: () => ({skills: [], diagnostics: []}),
    getPrompts: () => ({prompts: [], diagnostics: []}),
    getThemes: () => ({themes: [], diagnostics: []}),
    getAgentsFiles: () => ({agentsFiles: []}),
    getSystemPrompt: () => request.tools ? undefined : request.system,
    getSystemPromptSource: () => undefined,
    getAppendSystemPrompt: () => request.tools ? [request.system] : [],
    getAppendSystemPromptSources: () => [],
    extendResources: () => {},
    reload: async () => {},
  };

  // Web access comes from the pinned pi-web-access extension (zero-config Exa search).
  // The host supplies its own resource loader, so extensions must be loaded here explicitly.
  const webExtension = new URL('./node_modules/pi-web-access/dist', import.meta.url).pathname;
  const webTools = request.webSearch ? ['web_search', 'fetch_content'] : [];
  let loadedExtensions = null;
  if (request.webSearch) {
    loadedExtensions = await discoverAndLoadExtensions([webExtension], cwd, agentDir);
    for (const failure of loadedExtensions.errors ?? []) {
      process.stderr.write(`SW_EXTENSION_ERROR ${String(failure.error).slice(0, 200)}\n`);
    }
    progress({type: 'web_tools', count: loadedExtensions.extensions?.length ?? 0});
  }

  ({session} = await createAgentSession({
    cwd,
    agentDir,
    modelRuntime,
    model: modelRuntime.getModel(provider, request.model),
    thinkingLevel: 'off',
    resourceLoader,
    sessionManager: SessionManager.inMemory(cwd),
    settingsManager: SettingsManager.inMemory({compaction: {enabled: false}, retry}),
    noTools: !request.tools && !request.webSearch,
    tools: request.workspaceTools === false
         ? webTools
         : (request.tools ? ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', ...webTools]
            : (request.webSearch ? webTools : [])),
  }));
  process.once('SIGTERM', abort);

  const unsubscribe = session.subscribe((event) => {
    if (event.type === 'turn_start') {
      turns += 1;
      progress({type: 'turn', n: turns});
    } else if (event.type === 'tool_execution_start') {
      toolCalls += 1;
      toolNumbers.set(event.toolCallId, toolCalls);
      progress({type: 'tool', n: toolCalls, name: event.toolName, detail: describeToolArgs(event.args)});
      if (toolCalls > budgetToolCalls) hitBudget('toolCalls', budgetToolCalls);
    } else if (event.type === 'tool_execution_end') {
      const n = toolNumbers.get(event.toolCallId) ?? toolCalls;
      toolNumbers.delete(event.toolCallId);
      progress({
        type: 'tool_end',
        n,
        name: event.toolName,
        ms: Number.isFinite(event.durationMs) ? Math.max(0, Math.round(event.durationMs)) : 0,
        ok: !event.isError,
      });
    } else if (event.type === 'auto_retry_start') {
      progress({
        type: 'retry',
        attempt: event.attempt,
        max: event.maxAttempts,
        delayMs: event.delayMs,
        error: String(event.errorMessage ?? '').slice(0, 160),
      });
    } else if (event.type === 'auto_retry_end') {
      progress({type: 'retry_end', success: Boolean(event.success), attempt: event.attempt});
    }
  });

  progress({type: 'start', model: String(request.model)});
  const budgetTimer = setTimeout(() => hitBudget('minutes', budgetMinutes), budgetMinutes * 60000);
  budgetTimer.unref?.();
  let warned = false;
  const wrapUpTimer = setTimeout(() => {
    if (budget || warned) return;
    warned = true;
    progress({type: 'wrap_up', minutes: Math.round((Date.now() - startedAt) / 60000), limit: budgetMinutes});
    try {
      session.steer(`时间提醒：已用 ${Math.round((Date.now() - startedAt) / 60000)} 分钟，上限 ${budgetMinutes} 分钟。`
        + '立即停止新增镜头与探索，保留当前实现，尽快完成整片渲染并交付指定输出文件。');
    } catch {}
  }, budgetMinutes * 60000 * wrapUpRatio);
  wrapUpTimer.unref?.();

  let promptError;
  try {
    await session.prompt(request.prompt, {images: request.attachments});
  } catch (error) {
    promptError = error;
  } finally {
    clearTimeout(budgetTimer);
    clearTimeout(wrapUpTimer);
    unsubscribe();
  }

  if (budget) {
    const used = budget.reason === 'minutes'
      ? `${Math.round((Date.now() - startedAt) / 60000)} 分钟`
      : `${toolCalls} 次工具调用`;
    const limit = budget.reason === 'minutes'
      ? `${budgetMinutes} 分钟`
      : `${budgetToolCalls} 次工具调用`;
    throw new Error(`任务超出预算（${used}，上限 ${limit}），已中止。`);
  }
  if (promptError) throw promptError;

  const message = session.messages.findLast(({role}) => role === 'assistant');
  if (!message || message.stopReason === 'error' || message.stopReason === 'aborted') {
    throw new Error(message?.errorMessage || 'Pi did not complete the request.');
  }
  const text = message.content.filter(({type}) => type === 'text').map(({text}) => text).join('\n');
  if (!text.trim()) throw new Error('Pi returned no text.');
  progress({type: 'done', ms: Date.now() - startedAt, tools: toolCalls});
  process.stdout.write(text + '\n');
} catch (error) {
  let message = error instanceof Error ? error.message : 'Pi could not complete the request.';
  if (request.key) message = message.replaceAll(request.key, '[redacted]');
  process.stderr.write(message.slice(0, 1000) + '\n');
  process.exitCode = 1;
} finally {
  process.removeListener('SIGTERM', abort);
  session?.dispose();
  await rm(agentDir, {recursive: true, force: true});
}
