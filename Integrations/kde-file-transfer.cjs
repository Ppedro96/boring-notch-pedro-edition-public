#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { pathToFileURL } = require('node:url');
const dbus = require('dbus-next');
const { relayHost } = require('./local-config.cjs').loadConfig();

const service = 'org.kde.kdeconnect';
const deviceInterface = service + '.device';
const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
function emit(value) { if (!process.stdout.destroyed) process.stdout.write(JSON.stringify(value) + '\n'); }
function validateManifest(m) {
  if (!m || !/^[0-9a-f-]{36}$/i.test(m.id) || !/^[a-zA-Z0-9_]{1,128}$/.test(m.device) ||
      typeof m.name !== 'string' || !m.name || m.name === '.' || m.name === '..' ||
      /[\/\\\x00-\x1f]/.test(m.name) || Buffer.byteLength(m.name) > 255 ||
      !Number.isSafeInteger(m.size) || m.size < 0) throw Error('Arquivo ou aparelho invalido');
  return m;
}

// Match only this KDE job, never use a D-Bus method acknowledgement as completion.
class JobProgress {
  constructor(name, size, deviceName, publish) {
    this.name = name; this.size = size; this.deviceName = deviceName; this.publish = publish;
    this.jobs = new Map(); this.selected = null; this.resolve = null; this.lastSeen = Date.now();
    this.result = new Promise(resolve => { this.resolve = resolve; });
  }
  message(m) {
    if (!['org.kde.JobViewV2', 'org.kde.JobViewV3'].includes(m.interface)) return;
    let job = this.jobs.get(m.path);
    if (!job) { job = { title: '', name: '', total: null, bytes: 0, error: 0 }; this.jobs.set(m.path, job); }
    const body = m.body || [];
    if (m.member === 'setInfoMessage') job.title = body[0];
    if (m.member === 'setDescriptionField' && body[0] === 0) job.name = body[2];
    if (m.member === 'setTotalAmount' && body[1] === 'bytes') job.total = Number(body[0]);
    if (m.member === 'setProcessedAmount' && body[1] === 'bytes') job.bytes = Number(body[0]);
    if (m.member === 'setError') job.error = Number(body[0]);
    if (m.member === 'update') {
      const fields = Object.fromEntries(Object.entries(body[0] || {}).map(([k, v]) => [k, v.value]));
      if (fields.infoMessage !== undefined) job.title = fields.infoMessage;
      if (fields.title !== undefined) job.title = fields.title;
      if (fields.descriptionValue1 !== undefined) job.name = fields.descriptionValue1;
      if (fields.totalBytes !== undefined) job.total = Number(fields.totalBytes);
      if (fields.processedBytes !== undefined) job.bytes = Number(fields.processedBytes);
    }
    if (!this.selected && job.name === this.name && job.title.includes(this.deviceName) && job.total === this.size) this.selected = m.path;
    if (this.selected !== m.path) return;
    this.lastSeen = Date.now();
    if (job.name !== this.name || job.total !== this.size) {
      this.resolve({ phase: 'unknown', detail: 'KDE agrupou outro envio; conclusao individual nao confirmada' }); return;
    }
    if (m.member === 'terminate') {
      const code = m.interface === 'org.kde.JobViewV3' ? Number(body[0]) : job.error;
      const detail = m.interface === 'org.kde.JobViewV3' ? body[1] : body[0];
      this.resolve(code || detail ? { phase: 'failed', detail: String(detail || 'KDE interrompeu o envio') } :
        { phase: 'completed', bytes: this.size, total: this.size, detail: 'Enviado pelo KDE Connect' });
    } else {
      this.publish({ phase: 'sending', bytes: Math.min(this.size, Math.max(0, job.bytes)), total: this.size, detail: 'X99 > ' + this.deviceName });
    }
  }
}

async function receiveFile(input, file, size, publish) {
  const handle = await fsp.open(file, 'wx', 0o600);
  const hash = crypto.createHash('sha256');
  let bytes = 0, trailer = Buffer.alloc(0), last = 0, verified = false;
  try {
    for await (const raw of input) {
      const chunk = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
      const length = Math.min(chunk.length, size - bytes);
      if (length > 0) {
        const payload = chunk.subarray(0, length);
        let written = 0;
        while (written < payload.length) written += (await handle.write(payload, written, payload.length - written)).bytesWritten;
        hash.update(payload); bytes += length;
        if (Date.now() - last > 150 || bytes === size) {
          publish({ phase: 'staging', bytes, total: size, detail: 'Mac > X99' }); last = Date.now();
        }
      }
      if (length < chunk.length) trailer = Buffer.concat([trailer, chunk.subarray(length)]);
      if (trailer.length > 100) throw Error('Protocolo de envio invalido');
    }
    if (bytes !== size || !/^[a-f0-9]{64}\n$/.test(trailer.toString()) ||
        hash.digest('hex') !== trailer.toString().trim()) throw Error('Copia interrompida ou arquivo alterado');
    await handle.sync(); verified = true;
  } finally {
    await handle.close();
    if (!verified) await fsp.unlink(file).catch(() => {});
  }
}

async function remote(manifest) {
  validateManifest(manifest);
  const socket = '/run/user/' + process.getuid() + '/bus';
  const socketStat = await fsp.lstat(socket);
  if (!socketStat.isSocket() || socketStat.uid !== process.getuid()) throw Error('Sessao KDE indisponivel');
  const bus = dbus.sessionBus({ busAddress: 'unix:path=' + socket });
  let monitor, directory, retain = false;
  const call = async (destination, object, iface, member, signature = '', body = []) =>
    (await bus.call(new dbus.Message({ destination, path: object, interface: iface, member, signature, body }))).body[0];
  try {
    const object = '/modules/kdeconnect/devices/' + manifest.device;
    const props = await call(service, object, 'org.freedesktop.DBus.Properties', 'GetAll', 's', [deviceInterface]);
    if (!props.isPaired?.value || !props.isReachable?.value) throw Error('Aparelho desconectado ou nao pareado');
    const plugins = await call(service, object, deviceInterface, 'loadedPlugins');
    if (!plugins.includes('kdeconnect_share')) throw Error('Compartilhamento desativado no aparelho');
    const base = path.join(os.homedir(), '.cache/pedro-notch/transfers');
    await fsp.mkdir(base, { recursive: true, mode: 0o700 });
    const baseStat = await fsp.lstat(base);
    if (!baseStat.isDirectory() || baseStat.isSymbolicLink() || baseStat.uid !== process.getuid()) throw Error('Pasta temporaria invalida');
    await fsp.chmod(base, 0o700);
    // Only remove our own, old UUID staging folders, never a user's source file.
    for (const name of await fsp.readdir(base)) {
      if (!/^[0-9a-f-]{36}$/i.test(name)) continue;
      const old = path.join(base, name), st = await fsp.lstat(old);
      if (st.isDirectory() && !st.isSymbolicLink() && st.uid === process.getuid() && Date.now() - st.mtimeMs > 86400000)
        await fsp.rm(old, { recursive: true });
    }
    directory = path.join(base, manifest.id);
    await fsp.mkdir(directory, { mode: 0o700 });
    const file = path.join(directory, manifest.name);
    await receiveFile(process.stdin, file, manifest.size, emit);
    emit({ phase: 'verifying', detail: 'Copia verificada; conectando ao aparelho' });
    const owner = await call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetNameOwner', 's', [service]);
    const tracker = new JobProgress(manifest.name, manifest.size, String(props.name.value), emit);
    monitor = dbus.sessionBus({ busAddress: 'unix:path=' + socket });
    monitor.addMethodHandler(() => true);
    monitor.on('error', () => tracker.resolve({ phase: 'unknown', detail: 'Monitor KDE desconectou; conclusao nao confirmada' }));
    monitor.on('message', message => { if (message.sender === owner) tracker.message(message); });
    await monitor.call(new dbus.Message({ destination: 'org.freedesktop.DBus', path: '/org/freedesktop/DBus',
      interface: 'org.freedesktop.DBus.Monitoring', member: 'BecomeMonitor', signature: 'asu', body: [
        ["type='method_call',sender='" + owner + "',interface='org.kde.JobViewV2'",
         "type='method_call',sender='" + owner + "',interface='org.kde.JobViewV3'"], 0] }));
    emit({ phase: 'sending', bytes: 0, total: manifest.size, detail: 'X99 > ' + String(props.name.value) });
    await call(service, object + '/share', deviceInterface + '.share', 'shareUrl', 's', [pathToFileURL(file).href]);
    retain = true;
    let timer;
    const started = Date.now();
    const result = await Promise.race([tracker.result, new Promise(resolve => {
      timer = setInterval(() => {
        if (!tracker.selected && Date.now() - started > 3000) resolve({ phase: 'submitted', detail: 'Entregue ao KDE; envio rapido sem confirmacao publicada' });
        else if (Date.now() - tracker.lastSeen > 120000) resolve({ phase: 'unknown', detail: 'KDE parou de informar progresso; conclusao nao confirmada' });
      }, 1000);
    })]);
    clearInterval(timer);
    retain = ['unknown', 'submitted'].includes(result.phase);
    emit(result);
  } finally {
    monitor?.disconnect(); bus.disconnect();
    if (directory && !retain) await fsp.rm(directory, { recursive: true, force: true });
  }
}

async function send(device, filename) {
  const file = await fsp.open(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  let child, source, idle, terminal = false, cancelled = false, committed = false;
  const cancel = () => {
    if (committed) return;
    cancelled = true; source?.destroy(); child?.kill('SIGTERM');
  };
  process.once('SIGTERM', cancel); process.once('SIGINT', cancel);
  try {
    const st = await file.stat();
    if (!st.isFile()) throw Error('Selecione arquivos, nao pastas');
    const manifest = validateManifest({ id: crypto.randomUUID(), device: device.replace(/^x99:/, ''), name: path.basename(filename), size: st.size });
    if (!device.startsWith('x99:')) throw Error('Envio acompanhado requer a ponte X99');
    if (!relayHost) throw Error('Configure o relay SSH do KDE Connect');
    const args = ['node', '.local/share/pedro-notch/kde-file-transfer.cjs', 'receive', Buffer.from(JSON.stringify(manifest)).toString('base64')];
    child = spawn('/usr/bin/ssh', ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', '-o', 'ServerAliveInterval=15',
      '-o', 'ServerAliveCountMax=3', relayHost, args.map(quote).join(' ')], { stdio: ['pipe', 'pipe', 'pipe'] });
    let lines = '', stderr = '';
    const resetIdle = () => { clearTimeout(idle); idle = setTimeout(() => child.kill('SIGTERM'), 180000); };
    resetIdle();
    child.stdout.on('data', chunk => {
      resetIdle(); lines += chunk.toString();
      if (lines.length > 65536) { child.kill('SIGTERM'); return; }
      let index;
      while ((index = lines.indexOf('\n')) >= 0) {
        const line = lines.slice(0, index); lines = lines.slice(index + 1);
        try {
          const event = JSON.parse(line);
          if (['completed', 'failed', 'unknown', 'cancelled', 'submitted'].includes(event.phase)) terminal = true;
          emit(event);
        } catch {}
      }
    });
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-2000); });
    const ended = new Promise((resolve, reject) => {
      child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal }));
    });
    child.stdin.on('error', () => source?.destroy());
    source = file.createReadStream({ autoClose: false, highWaterMark: 256 * 1024 });
    const hash = crypto.createHash('sha256');
    try {
      for await (const chunk of source) {
        if (cancelled || child.stdin.destroyed) break;
        resetIdle(); hash.update(chunk);
        if (!child.stdin.write(chunk)) await Promise.race([once(child.stdin, 'drain'), ended]);
      }
      const after = await file.stat();
      if (!cancelled && !child.stdin.destroyed && st.size === after.size && st.mtimeMs === after.mtimeMs && st.ctimeMs === after.ctimeMs) {
        committed = true;
        emit({ phase: 'verifying', detail: 'Verificando copia no X99' });
        child.stdin.end(hash.digest('hex') + '\n');
      } else child.stdin.destroy();
    } catch { child.stdin.destroy(); }
    const exit = await ended;
    if (!terminal) emit({ phase: cancelled ? 'cancelled' : 'failed', detail: cancelled ? 'Copia cancelada' :
      (exit.code === 255 ? 'Ponte X99 indisponivel' : 'Envio interrompido ou integracao X99 indisponivel') });
  } finally {
    clearTimeout(idle); await file.close(); process.removeListener('SIGTERM', cancel); process.removeListener('SIGINT', cancel);
  }
}

module.exports = { validateManifest, receiveFile, JobProgress, quote };
if (require.main === module) {
  process.stdout.on('error', () => {});
  const timeout = setTimeout(() => { emit({ phase: 'unknown', detail: 'Tempo limite da transferencia' }); process.exit(1); }, 3600000);
  const operation = process.argv[2] === 'receive' ? remote(JSON.parse(Buffer.from(process.argv[3] || '', 'base64').toString())) :
    process.argv[2] === 'send' ? send(process.argv[3] || '', process.argv[4] || '') : Promise.reject(Error('Comando invalido'));
  operation.catch(error => emit({ phase: 'failed', detail: String(error.message).slice(0, 300) })).finally(() => { clearTimeout(timeout); });
}
