#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const { execFileSync, spawn } = require('node:child_process');
const readline = require('node:readline');
const dbus = require('dbus-next');
const root = '/modules/kdeconnect', service = 'org.kde.kdeconnect', iface = service + '.device';
const validID = value => typeof value === 'string' && /^[a-zA-Z0-9_]{1,128}$/.test(value);
const quote = value => "'" + String(value).replace(/'/g, "'\\''") + "'";
const { relayHost, deviceNames: names } = require('./local-config.cjs').loadConfig();
const clean = (value, max) => String(value || '').slice(0, max);
function atomicWrite(file, contents) {
  const temp = file + '.' + require('node:crypto').randomUUID() + '.tmp';
  try { fs.writeFileSync(temp, contents, {mode: 0o600, flag: 'wx'}); fs.renameSync(temp, file); }
  finally { if (fs.existsSync(temp)) fs.unlinkSync(temp); }
}
function offline(devices) {
  return devices.map(p => ({ ...p, reachable: false, charge: null, charging: false, notifications: [], media: null }));
}
function mergeDevices(local, remote) {
  const devices = local.map(p => ({ ...p }));
  for (const p of remote) {
    const index = devices.findIndex(d => d.id === p.id);
    if (index >= 0 && devices[index].reachable) continue;
    if (index >= 0) devices.splice(index, 1);
    devices.push({ ...p, id: 'x99:' + p.id, via: 'X99', canShareFiles: true });
  }
  return devices;
}
function validateAction(request) {
  if (!request || !validID(request.id)) throw Error('Dispositivo invalido');
  if (request.command === 'reply') {
    if (!validID(request.notification) || typeof request.replyID !== 'string' || !request.replyID || request.replyID.length > 2048 ||
        typeof request.text !== 'string' || !request.text.trim() || Buffer.byteLength(request.text) > 4096) throw Error('Resposta invalida');
  } else if (request.command === 'media') {
    if (!['Previous', 'PlayPause', 'Next', 'select'].includes(request.action) || typeof request.player !== 'string' ||
        !request.player || request.player.length > 200) throw Error('Controle de midia invalido');
  } else if (!['ring', 'share'].includes(request.command)) throw Error('Acao invalida');
  return request;
}
class LocalKDE {
  constructor() { this.bus = null; this.inflight = null; this.stopped = false; this.onChange = () => {}; }
  async connect() {
    const socket = process.platform === 'linux' ? '/run/user/' + process.getuid() + '/bus' :
      execFileSync('/bin/launchctl', ['getenv', 'DBUS_LAUNCHD_SESSION_BUS_SOCKET'], { encoding: 'utf8', timeout: 1500 }).trim();
    if (!(process.platform === 'linux' ? /^\/run\/user\/\d+\/bus$/ : /^\/tmp\/dbus-[a-zA-Z0-9]+$/).test(socket)) throw Error('Abra o KDE Connect');
    const stat = fs.lstatSync(socket);
    if (!stat.isSocket() || stat.uid !== process.getuid()) throw Error('Socket local do KDE Connect invalido');
    this.bus = dbus.sessionBus({ busAddress: 'unix:path=' + socket });
    this.bus.on('error', () => this.lost());
    this.bus._connection.on('end', () => this.lost());
    this.bus.on('message', message => {
      if (message.type !== dbus.MessageType.SIGNAL) return;
      if (message.path?.startsWith(root) || (message.interface === 'org.freedesktop.DBus' && message.member === 'NameOwnerChanged' && message.body[0] === service)) this.onChange();
    });
    // Match by the well-known sender: this continues working after a daemon restart.
    await this.bus.call(new dbus.Message({ destination: 'org.freedesktop.DBus', path: '/org/freedesktop/DBus',
      interface: 'org.freedesktop.DBus', member: 'AddMatch', signature: 's', body: ["type='signal',sender='org.kde.kdeconnect'"] }));
    await this.bus.call(new dbus.Message({ destination: 'org.freedesktop.DBus', path: '/org/freedesktop/DBus',
      interface: 'org.freedesktop.DBus', member: 'AddMatch', signature: 's', body: ["type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.kdeconnect'"] }));
  }
  lost() { const old = this.bus; this.bus = null; old?.disconnect(); if (!this.stopped) this.onChange(); }
  close() { this.stopped = true; this.bus?.disconnect(); this.bus = null; }
  async call(path, name, member, signature = '', body = []) {
    if (!this.bus) throw Error('KDE Connect local indisponivel');
    const active = this.bus;
    let timer;
    try {
      const reply = await Promise.race([
        active.call(new dbus.Message({ destination: service, path, interface: name, member, signature, body })),
        new Promise((_, reject) => { timer = setTimeout(() => reject(Error('KDE Connect nao respondeu')), 4000); })
      ]);
      return reply.body[0];
    } catch (error) { if (this.bus === active && !error.type) this.lost(); throw error; }
    finally { clearTimeout(timer); }
  }
  async props(path, name) {
    const values = await this.call(path, 'org.freedesktop.DBus.Properties', 'GetAll', 's', [name]);
    return Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value.value]));
  }
  async snapshot() {
    const ids = await this.call(root, service + '.daemon', 'devices', 'bb', [false, false]);
    const devices = [];
    for (const id of ids.slice(0, 12)) {
      if (!validID(id)) continue;
      const path = root + '/devices/' + id, p = await this.props(path, iface);
      if (!['phone', 'tablet'].includes(p.type)) continue;
      const device = { id, name: names.get(id) ?? clean(p.name, 100), paired: !!p.isPaired, reachable: !!p.isReachable,
        charge: null, charging: false, notifications: [], notificationsAvailable: false, canRing: false,
        canShare: false, canShareFiles: true, via: null, media: null };
      if (device.paired && device.reachable) {
        const plugins = await this.call(path, iface, 'loadedPlugins');
        device.canRing = plugins.includes('kdeconnect_findmyphone'); device.canShare = plugins.includes('kdeconnect_share');
        if (plugins.includes('kdeconnect_battery')) try {
          const b = await this.props(path + '/battery', iface + '.battery');
          device.charge = b.hasBattery !== false && b.charge >= 0 && b.charge <= 100 ? b.charge : null; device.charging = !!b.isCharging;
        } catch {}
        if (plugins.includes('kdeconnect_notifications')) try {
          const nids = await this.call(path + '/notifications', iface + '.notifications', 'activeNotifications');
          device.notificationsAvailable = true;
          for (const nid of nids.slice(-30)) {
            if (!validID(nid)) continue;
            try {
              const n = await this.props(path + '/notifications/' + nid, iface + '.notifications.notification');
              device.notifications.push({ id: nid, app: clean(n.appName, 100), title: clean(n.title, 250),
                text: clean(n.text || n.ticker, 2000), replyID: clean(n.replyId, 2048), silent: !!n.silent });
            } catch {} // A notification may disappear while this snapshot is being read.
          }
        } catch {}
        if (plugins.includes('kdeconnect_mprisremote')) try {
          const m = await this.props(path + '/mprisremote', iface + '.mprisremote');
          device.media = { players: (m.playerList || []).map(v => clean(v, 200)), player: clean(m.player, 200),
            title: clean(m.title, 300), artist: clean(m.artist, 200), playing: !!m.isPlaying,
            // Artwork is local only; a relay path is never read as a Mac path.
            artwork: process.platform === 'darwin' && String(m.localAlbumArtUrl || '').startsWith('file:') ? m.localAlbumArtUrl : null };
        } catch {}
      }
      devices.push(device);
    }
    return devices;
  }
  async action(request) {
    const r = validateAction(request), path = root + '/devices/' + r.id;
    const p = await this.props(path, iface);
    if (!p.isReachable || !p.isPaired) throw Error('Celular desconectado ou nao pareado');
    if (r.command === 'ring') await this.call(path + '/findmyphone', iface + '.findmyphone', 'ring');
    if (r.command === 'share') {
      const url = new URL(r.value || '');
      if (!['https:', 'http:', 'file:'].includes(url.protocol) || url.username || url.password) throw Error('Link invalido');
      if (url.protocol === 'file:' && (url.hostname || !fs.statSync(url).isFile())) throw Error('Arquivo invalido');
      await this.call(path + '/share', iface + '.share', 'shareUrl', 's', [url.href]);
    }
    if (r.command === 'reply') {
      const np = path + '/notifications/' + r.notification;
      const n = await this.props(np, iface + '.notifications.notification');
      if (!n.replyId || n.replyId !== r.replyID) throw Error('Esta notificacao expirou; atualize antes de responder');
      await this.call(np, iface + '.notifications.notification', 'sendReply', 's', [r.text]);
    }
    if (r.command === 'media') {
      const mp = path + '/mprisremote', mi = iface + '.mprisremote', m = await this.props(mp, mi);
      if (!(m.playerList || []).includes(r.player)) throw Error('Este player nao esta mais disponivel');
      if (m.player !== r.player) await this.call(mp, 'org.freedesktop.DBus.Properties', 'Set', 'ssv', [mi, 'player', new dbus.Variant('s', r.player)]);
      if (r.action !== 'select') await this.call(mp, mi, 'sendAction', 's', [r.action]);
    }
    return { ok: true };
  }
}
function remoteProcess(command) {
  if (!relayHost) throw Error('Configure o relay SSH do KDE Connect');
  return spawn('/usr/bin/ssh', ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', '-o', 'ServerAliveInterval=10',
    '-o', 'ServerAliveCountMax=2', relayHost, ['node', '.local/share/pedro-notch/kde-phone.cjs', command].map(quote).join(' ')], { stdio: ['pipe', 'pipe', 'pipe'] });
}
function remoteAction(request) {
  return new Promise((resolve, reject) => {
    const child = remoteProcess('action'); let output = '';
    const timer = setTimeout(() => { child.kill(); reject(Error('Ponte X99 nao respondeu')); }, 8000);
    child.stdout.on('data', data => { output += data; if (output.length > 65536) child.kill(); });
    child.stderr.resume(); child.on('error', reject);
    child.on('close', () => { clearTimeout(timer); try { resolve(JSON.parse(output)); } catch { reject(Error('Ponte X99 indisponivel')); } });
    child.stdin.on('error', () => {}); child.stdin.end(JSON.stringify(request));
  });
}
function restorePopupConfiguration(current, original, managed) {
  if (current === managed) return original;
  if (current === null) return null;
  const section = /(^\[Event\/notification\][^\n]*\n)([\s\S]*?)(?=^\[|$(?![\s\S]))/m;
  const oldSection = (original || '').match(section);
  const oldAction = oldSection?.[2].match(/^Action=.*$/m)?.[0];
  return current.replace(section, (all, header, body) => {
    if (!/^Action=None\s*$/m.test(body)) return all; // Explicit user changes win.
    const restored = oldAction ? body.replace(/^Action=None[^\n]*$/m, oldAction) : body.replace(/^Action=None[^\n]*\n?/m, '');
    return !oldSection && !restored.trim() ? '' : header + restored;
  });
}
// Only the forwarding popup is replaced; pairing/call/battery/error events stay with KDE.
class NativePopupOwner {
  constructor(local, file = require('node:path').join(require('node:os').homedir(), 'Library/Preferences/kdeconnect.notifyrc'), state = require('node:path').join(require('node:os').homedir(), '.local/share/pedro-notch/kde-native-popup-owner.json')) {
    this.local = local; this.file = file; this.state = state; this.previous = undefined; this.managed = null;
  }
  async reparse() {
    if (!this.local.bus) return;
    this.local.bus.send(new dbus.Message({ type: dbus.MessageType.SIGNAL, path: '/Config', interface: 'org.kde.knotification',
      member: 'reparseConfiguration', signature: 's', body: ['kdeconnect'] }));
    let timer;
    try {
      await Promise.race([
        this.local.bus.call(new dbus.Message({ destination: 'org.freedesktop.DBus', path: '/org/freedesktop/DBus', interface: 'org.freedesktop.DBus', member: 'ListNames' })),
        new Promise(resolve => { timer = setTimeout(resolve, 1000); })
      ]);
    } finally { clearTimeout(timer); }
  }
  read() { try { return fs.readFileSync(this.file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return null; throw e; } }
  async recover() {
    if (!fs.existsSync(this.state)) return;
    const old = JSON.parse(fs.readFileSync(this.state, 'utf8'));
    if (old.pid) {
      try { process.kill(old.pid, 0); return; } catch {}
    }
    const current = this.read(), restored = restorePopupConfiguration(current, old.original, old.managed);
    if (restored !== current) { if (restored === null) fs.unlinkSync(this.file); else atomicWrite(this.file, restored); }
    fs.unlinkSync(this.state);
    await this.reparse();
  }
  async set(enabled) {
    if (enabled && this.managed === null) {
      await this.recover();
      if (fs.existsSync(this.state)) throw Error('Outro observador ja controla os avisos');
      this.previous = this.read();
      const original = this.previous || '';
      const section = /(^\[Event\/notification\][^\n]*\n)([\s\S]*?)(?=^\[|$(?![\s\S]))/m;
      if (section.test(original)) {
        this.managed = original.replace(section, (_, header, body) => header + (/^Action=.*$/m.test(body) ? body.replace(/^Action=.*$/m, 'Action=None') : 'Action=None\n' + body));
      } else this.managed = original + '\n[Event/notification]\nAction=None\n';
      atomicWrite(this.state, JSON.stringify({ original: this.previous, managed: this.managed, pid: process.pid }));
      atomicWrite(this.file, this.managed);
      await this.reparse();
    }
    if (!enabled && this.managed !== null) {
      // Restore only our Action=None override, preserving unrelated user edits.
      const current = this.read(), restored = restorePopupConfiguration(current, this.previous, this.managed);
      if (restored !== current) { if (restored === null) fs.unlinkSync(this.file); else atomicWrite(this.file, restored); }
      this.managed = null;
      if (fs.existsSync(this.state)) fs.unlinkSync(this.state);
      await this.reparse();
    }
  }
}

class PhoneWatch {
  constructor(publish, { local = new LocalKDE(), relay = process.platform === 'darwin' && Boolean(relayHost), remoteFactory = remoteProcess } = {}) {
    this.publish = publish; this.local = local; this.relay = relay; this.remoteFactory = remoteFactory;
    this.direct = []; this.remote = []; this.localError = null; this.relayError = null; this.nativeError = null;
    this.timer = null; this.retry = null; this.child = null; this.stopped = false; this.busy = false; this.again = false;
    this.last = ''; this.retryDelay = 3000;
    local.onChange = () => this.schedule();
  }
  emit() {
    const result = { devices: mergeDevices(this.direct, this.remote), error: [this.localError, this.relayError, this.nativeError].filter(Boolean).join(' · ') || null };
    const signature = JSON.stringify(result);
    if (signature === this.last) return;
    this.last = signature; this.publish({ ...result, updatedAt: Date.now() / 1000 });
  }
  schedule() {
    if (this.stopped) return;
    if (this.busy) { this.again = true; return; }
    clearTimeout(this.timer); this.timer = setTimeout(() => this.refresh(), 120);
  }
  async refresh() {
    if (this.stopped) return;
    if (this.busy) { this.again = true; return; }
    this.busy = true;
    try {
      if (!this.local.bus) await this.local.connect();
      this.direct = await this.local.snapshot(); this.localError = null;
    } catch { this.direct = offline(this.direct); this.localError = 'KDE Connect local indisponivel'; }
    this.busy = false;
    if (this.stopped) return;
    this.emit();
    if (this.localError) { clearTimeout(this.timer); this.timer = setTimeout(() => this.refresh(), 3000); }
    else if (this.again) { this.again = false; this.schedule(); }
  }
  startRemote() {
    if (this.stopped || !this.relay) return;
    const child = this.remoteFactory('watch'); this.child = child;
    child.stdin.on('error', () => {}); child.stderr.resume();
    const firstFrame = setTimeout(() => child.kill(), 7000);
    const lines = readline.createInterface({ input: child.stdout });
    lines.on('line', line => {
      if (line.length > 1024 * 1024 || this.stopped) return;
      try {
        const snapshot = JSON.parse(line);
        if (!Array.isArray(snapshot.devices)) return;
        clearTimeout(firstFrame);
        this.remote = snapshot.devices; this.relayError = snapshot.error ? 'KDE Connect no X99 indisponivel' : null;
        this.retryDelay = 3000; this.emit();
      } catch {}
    });
    child.on('error', () => {});
    child.once('close', () => {
      clearTimeout(firstFrame); lines.close(); if (this.child === child) this.child = null;
      if (this.stopped) return;
      this.remote = offline(this.remote); this.relayError = 'Ponte X99 indisponivel'; this.emit();
      this.retry = setTimeout(() => this.startRemote(), this.retryDelay); this.retryDelay = Math.min(30000, this.retryDelay * 2);
    });
  }
  start() { this.refresh(); this.startRemote(); }
  manualRefresh() { this.refresh(); if (this.child?.stdin.writable) this.child.stdin.write('{"command":"refresh"}\n'); }
  stop() { this.stopped = true; clearTimeout(this.timer); clearTimeout(this.retry); this.child?.kill(); this.local.close(); }
}
async function readRequest() {
  let input = '';
  for await (const chunk of process.stdin) { input += chunk; if (Buffer.byteLength(input) > 16384) throw Error('Acao muito grande'); }
  return JSON.parse(input);
}
async function main() {
  const command = process.argv[2] || 'snapshot';
  if (command === 'watch') {
    const watcher = new PhoneWatch(value => process.stdout.write(JSON.stringify(value) + '\n'));
    const popupOwner = new NativePopupOwner(watcher.local);
    watcher.start();
    if (process.platform === 'darwin') popupOwner.recover().catch(() => {});
    const reader = readline.createInterface({ input: process.stdin });
    reader.on('line', line => {
      if (line === '{"command":"refresh"}') watcher.manualRefresh();
      if (process.platform === 'darwin') {
        if (['{"nativeNotifications":true}', '{"nativeNotifications":false}'].includes(line)) {
          popupOwner.set(JSON.parse(line).nativeNotifications).then(() => { watcher.nativeError = null; watcher.emit(); })
            .catch(() => { watcher.nativeError = 'Nao foi possivel ajustar os avisos duplicados do KDE'; watcher.emit(); });
        }
      }
    });
    let stopping = false;
    const stop = async () => {
      if (stopping) return; stopping = true;
      try { await popupOwner.set(false); } catch {}
      watcher.stop(); reader.close(); process.exit(0);
    };
    reader.on('close', stop); process.on('SIGTERM', stop); process.on('SIGINT', stop);
    process.stdout.on('error', stop); return;
  }
  if (command === 'snapshot') {
    const watcher = new PhoneWatch(() => {});
    const timeout = setTimeout(() => { watcher.stop(); process.exit(1); }, 7500);
    // Snapshot CLI remains compatible. App uses the independent event streams.
    const local = new LocalKDE();
    try {
      await local.connect(); const direct = await local.snapshot();
      let remote = [], error = null;
      if (process.platform === 'darwin' && relayHost) try {
        const child = remoteProcess('snapshot'); child.stdin.end(); child.stderr.resume(); let output = '';
        const timer = setTimeout(() => child.kill(), 5000);
        for await (const data of child.stdout) { output += data; if (output.length > 1024 * 1024) child.kill(); }
        clearTimeout(timer); remote = JSON.parse(output).devices || [];
      } catch { error = 'Ponte X99 indisponivel'; }
      process.stdout.write(JSON.stringify({ devices: mergeDevices(direct, remote), error, updatedAt: Date.now() / 1000 }) + '\n');
    } finally { clearTimeout(timeout); local.close(); }
    return;
  }
  const request = command === 'action' ? await readRequest() : { command, id: process.argv[3], value: process.argv[4] };
  if (process.platform === 'darwin' && request.id?.startsWith('x99:')) {
    request.id = request.id.slice(4); validateAction(request);
    if (request.command === 'share' && !/^https?:\/\//i.test(request.value || '')) throw Error('Envio de arquivo requer conexao direta');
    process.stdout.write(JSON.stringify(await remoteAction(request)) + '\n'); return;
  }
  const local = new LocalKDE();
  try { await local.connect(); process.stdout.write(JSON.stringify(await local.action(request)) + '\n'); } finally { local.close(); }
}
module.exports = { LocalKDE, PhoneWatch, mergeDevices, offline, validateAction, NativePopupOwner };
if (require.main === module) {
  const timeout = process.argv[2] === 'watch' ? null : setTimeout(() => { process.stdout.write('{"error":"KDE Connect nao respondeu a tempo"}\n'); process.exit(1); }, 9000);
  main().then(() => { if (timeout) clearTimeout(timeout); }).catch(error => {
    if (timeout) clearTimeout(timeout); process.stdout.write(JSON.stringify({ error: clean(error.message, 300) }) + '\n'); process.exit(1);
  });
}
