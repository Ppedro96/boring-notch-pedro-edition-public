// Uses the installed Gemini CLI's OAuth and quota client. No model prompts.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';

const finish = (value) => {
  process.stdout.write(JSON.stringify(value) + '\n');
  process.exit(0);
};
const deadline = setTimeout(() => finish({ ok: false, error: 'timeout' }), 18000);

try {
  const home = process.env.GEMINI_CLI_HOME || os.homedir();
  await fs.access(path.join(home, '.gemini', 'oauth_creds.json'));
  const candidates = [
    process.env.GEMINI_CLI_PATH,
    ...((process.env.PATH || '').split(path.delimiter).map(dir => path.join(dir, 'gemini'))),
    '/opt/homebrew/bin/gemini', '/usr/local/bin/gemini',
  ].filter(Boolean);
  let bundle;
  for (const candidate of candidates) {
    try {
      const entry = await fs.realpath(candidate);
      const directory = path.dirname(entry);
      if ((await fs.readdir(directory)).some(name => /^core-.*\.js$/.test(name))) {
        bundle = directory;
        break;
      }
    } catch {}
  }
  if (!bundle) finish({ ok: false, error: 'cli-not-installed' });
  let core;
  for (const name of (await fs.readdir(bundle)).filter(name => /^core-.*\.js$/.test(name)).sort()) {
    const candidate = await import(pathToFileURL(path.join(bundle, name)).href);
    if (candidate.getOauthClient && candidate.CodeAssistServer && candidate.AuthType) {
      core = candidate;
      break;
    }
  }
  if (!core) finish({ ok: false, error: 'cli-incompatible' });
  for (const method of ['log', 'debug', 'warn', 'error']) {
    if (core.debugLogger) core.debugLogger[method] = () => {};
  }
  const config = {
    getProxy: () => undefined,
    isBrowserLaunchSuppressed: () => true,
    isInteractive: () => false,
    getAcpMode: () => false,
  };
  // Suppressed browser + non-interactive prevents background login popups.
  const client = await core.getOauthClient(core.AuthType.LOGIN_WITH_GOOGLE, config);
  const service = new core.CodeAssistServer(client);
  const profile = await service.loadCodeAssist({
    metadata: { ideType: 'IDE_UNSPECIFIED', platform: 'PLATFORM_UNSPECIFIED', pluginType: 'GEMINI' },
    mode: 'HEALTH_CHECK',
  });
  const project = typeof profile.cloudaicompanionProject === 'string'
    ? profile.cloudaicompanionProject : profile.cloudaicompanionProject?.id;
  if (!project) finish({ ok: false, error: 'cli-not-ready' });
  const quota = await service.retrieveUserQuota({ project });
  const buckets = (quota.buckets || []).map(bucket => ({
    modelId: bucket.modelId,
    tokenType: bucket.tokenType,
    remainingFraction: bucket.remainingFraction,
    resetTime: bucket.resetTime,
  }));
  clearTimeout(deadline);
  finish({ ok: true, observedAt: new Date().toISOString(), buckets });
} catch (error) {
  // Never serialize SDK errors: request objects may contain OAuth credentials.
  const status = error?.response?.status;
  const code = error?.code === 'ENOENT' || error?.constructor?.name === 'FatalAuthenticationError'
    ? 'login-required' : status ? `http-${status}` : 'quota-unavailable';
  finish({ ok: false, error: code });
}
