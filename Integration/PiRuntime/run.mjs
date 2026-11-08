import {mkdtemp, rm} from 'node:fs/promises';
import {readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const request = JSON.parse(readFileSync(0, 'utf8'));
const cwd = process.cwd();
const agentDir = await mkdtemp(join(tmpdir(), 'superworkspace-pi-'));
process.env.PI_CODING_AGENT_DIR = agentDir;
const provider = 'workspace';
let session;
const abort = () => void session?.abort();

try {
  const {
    createAgentSession, createExtensionRuntime, ModelRuntime, SessionManager, SettingsManager,
  } = await import('@earendil-works/pi-coding-agent');
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
      maxTokens: request.tools ? 32768 : 4096,
      cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
    }],
  });
  // The key stays in process memory. Pi's bash tools never inherit it.
  await modelRuntime.setRuntimeApiKey(provider, request.key || 'local');

  const resourceLoader = {
    getExtensions: () => ({extensions: [], errors: [], runtime: createExtensionRuntime()}),
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

  ({session} = await createAgentSession({
    cwd,
    agentDir,
    modelRuntime,
    model: modelRuntime.getModel(provider, request.model),
    thinkingLevel: 'off',
    resourceLoader,
    sessionManager: SessionManager.inMemory(cwd),
    settingsManager: SettingsManager.inMemory({compaction: {enabled: false}, retry: {enabled: false}}),
    noTools: !request.tools,
    tools: request.tools ? ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'] : [],
  }));
  process.once('SIGTERM', abort);
  await session.prompt(request.prompt);
  const message = session.messages.findLast(({role}) => role === 'assistant');
  if (!message || message.stopReason === 'error' || message.stopReason === 'aborted') {
    throw new Error(message?.errorMessage || 'Pi did not complete the request.');
  }
  const text = message.content.filter(({type}) => type === 'text').map(({text}) => text).join('\n');
  if (!text.trim()) throw new Error('Pi returned no text.');
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
