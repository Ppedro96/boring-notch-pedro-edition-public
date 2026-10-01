#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');

function createEvent(options, now = Date.now() / 1000) {
  const { id, title, detail = '', state = 'completed', kind = 'dot', url, progress } = options;
  if (!id || id.length > 200 || !title || title.length > 300 || detail.length > 4000) throw Error('id, title ou detail invalido');
  if (!['running', 'waiting', 'completed', 'failed', 'cancelled', 'unknown'].includes(state)) throw Error('state invalido');
  if (!['dot', 'job', 'transfer'].includes(kind)) throw Error('kind invalido');
  if (progress !== undefined && (!Number.isFinite(Number(progress)) || Number(progress) < 0 || Number(progress) > 100)) throw Error('progress deve ser 0..100');
  if (url) {
    const parsed = new URL(url);
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) throw Error('url deve ser HTTP(S), sem credenciais');
  }
  const payload = { id, title, detail, kind, state, url: url || null, progress: progress === undefined ? null : Number(progress), outputPath: null };
  const revision = createHash('sha256').update(JSON.stringify(payload)).digest('hex');
  return { ...payload, revision, updatedAt: now };
}
function emit(options, directory = path.join(os.homedir(), '.pedroops/activity/events')) {
  const event = createEvent(options);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const target = path.join(directory, createHash('sha256').update(event.id).digest('hex') + '.json');
  // Identical retries keep both the revision and time, so a dismissed event stays dismissed.
  try { if (JSON.parse(fs.readFileSync(target, 'utf8')).revision === event.revision) return event; } catch {}
  const temp = target + '.' + process.pid + '.tmp';
  try {
    fs.writeFileSync(temp, JSON.stringify(event), { mode: 0o600, flag: 'wx' });
    fs.renameSync(temp, target);
  } finally { try { fs.unlinkSync(temp); } catch {} }
  return event;
}
if (require.main === module) {
  try {
    const args = process.argv.slice(2), options = {};
    const allowed = new Set(['id', 'title', 'detail', 'state', 'kind', 'url', 'progress']);
    for (let i = 0; i < args.length; i += 2) {
      const key = args[i].replace(/^--/, '');
      if (!allowed.has(key) || args[i + 1] === undefined) throw Error('Argumento invalido: ' + args[i]);
      options[key] = args[i + 1];
    }
    const event = emit(options);
    process.stdout.write(JSON.stringify({ ok: true, id: event.id, revision: event.revision }) + '\n');
  } catch (error) { process.stderr.write(error.message + '\n'); process.exitCode = 1; }
}
module.exports = { createEvent, emit };
