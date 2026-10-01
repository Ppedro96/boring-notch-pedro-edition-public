#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const dbus = require('dbus-next');
const root = '/modules/kdeconnect';
const service = 'org.kde.kdeconnect';
const iface = 'org.kde.kdeconnect.device';
const { relayHost, deviceNames } = require('./local-config.cjs').loadConfig();
const command = process.argv[2] || 'snapshot';
const id = process.argv[3];
let bus;
let relaySnapshot;
let finished = false;
function relayFallback(message) {
  return relaySnapshot?.devices ? { devices: relaySnapshot.devices.map(phone => ({ ...phone,
    id: 'x99:' + phone.id, via: 'X99', canShareFiles: true })), updatedAt: Date.now() / 1000 } : { error: message };
}
const timeout = setTimeout(() => finish(relayFallback('KDE Connect nao respondeu a tempo'), 1), 7000);
function finish(value, code = 0) {
  if (finished) return;
  finished = true;
  clearTimeout(timeout);
  bus?.disconnect();
  process.stdout.write(JSON.stringify(value) + '\n', () => process.exit(code));
}
async function call(path, interfaceName, member, signature = '', body = []) {
  const reply = await bus.call(new dbus.Message({ destination: service, path,
    interface: interfaceName, member, signature, body }));
  return reply.body[0];
}
async function properties(path, name) {
  const props = await call(path, 'org.freedesktop.DBus.Properties', 'GetAll', 's', [name]);
  return Object.fromEntries(Object.entries(props).map(([k, v]) => [k, v.value]));
}
function remote(command, id, value) {
  if (!relayHost) throw Error('Configure o relay SSH do KDE Connect');
  const quote = text => "'" + text.replace(/'/g, "'\\''") + "'";
  const args = ['node', '.local/share/pedro-notch/kde-phone.cjs', command, id, value].filter(v => v !== undefined);
  return JSON.parse(execFileSync('/usr/bin/ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', relayHost, args.map(quote).join(' ')],
    { encoding: 'utf8', timeout: 6500, maxBuffer: 512 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }));
}
async function main() {
  if (process.platform === 'darwin' && id?.startsWith('x99:')) {
    if (!['ring', 'share'].includes(command)) throw Error('Acao invalida');
    const remoteID = id.slice(4);
    if (!/^[a-zA-Z0-9_]{1,128}$/.test(remoteID)) throw Error('Dispositivo invalido');
    if (command === 'share' && !/^https?:\/\//i.test(process.argv[4] || '')) throw Error('Envio de arquivo requer conexao direta com o celular');
    return remote(command, remoteID, process.argv[4]);
  }
  if (process.platform === 'darwin' && command === 'snapshot') {
    try { relaySnapshot = remote('snapshot'); } catch {}
  }
  const socket = process.platform === 'linux' ? '/run/user/' + process.getuid() + '/bus' :
    execFileSync('/bin/launchctl', ['getenv', 'DBUS_LAUNCHD_SESSION_BUS_SOCKET'], { encoding: 'utf8', timeout: 1500 }).trim();
  if (!(process.platform === 'linux' ? /^\/run\/user\/\d+\/bus$/ : /^\/tmp\/dbus-[a-zA-Z0-9]+$/).test(socket)) throw Error('Abra o KDE Connect');
  const stat = fs.lstatSync(socket);
  if (!stat.isSocket() || stat.uid !== process.getuid()) throw Error('Socket local do KDE Connect invalido');
  bus = dbus.sessionBus({ busAddress: 'unix:path=' + socket });
  bus.on('error', () => finish(relayFallback('Conexao local com KDE Connect indisponivel'), 1));
  if (command === 'snapshot') {
    const ids = await call(root, 'org.kde.kdeconnect.daemon', 'devices', 'bb', [false, false]);
    const devices = [];
    for (const deviceID of ids.slice(0, 12)) {
      if (!/^[a-zA-Z0-9_]+$/.test(deviceID)) continue;
      const path = root + '/devices/' + deviceID;
      const p = await properties(path, iface);
      if (!['phone', 'tablet'].includes(p.type)) continue;
      const device = { id: deviceID, name: (deviceNames.get(deviceID) ?? String(p.name)).slice(0, 100), paired: !!p.isPaired,
        reachable: !!p.isReachable, charge: null, charging: false, notifications: [],
        notificationsAvailable: false, canRing: false, canShare: false, canShareFiles: true, via: null };
      if (device.paired && device.reachable) {
        const plugins = await call(path, iface, 'loadedPlugins');
        device.canRing = plugins.includes('kdeconnect_findmyphone');
        device.canShare = plugins.includes('kdeconnect_share');
        try {
          const b = await properties(path + '/battery', iface + '.battery');
          device.charge = b.hasBattery !== false && b.charge >= 0 && b.charge <= 100 ? b.charge : null;
          device.charging = !!b.isCharging;
        } catch {}
        try {
          const ids = await call(path + '/notifications', iface + '.notifications', 'activeNotifications');
          device.notificationsAvailable = true;
          for (const nid of ids.slice(-30)) {
            if (!/^[a-zA-Z0-9_]+$/.test(nid)) continue;
            const n = await properties(path + '/notifications/' + nid, iface + '.notifications.notification');
            device.notifications.push({ id: nid, app: String(n.appName || '').slice(0, 100),
              title: String(n.title || '').slice(0, 250), text: String(n.text || n.ticker || '').slice(0, 1000) });
          }
        } catch {}
      }
      devices.push(device);
    }
    let error;
    if (process.platform === 'darwin') {
      try {
        const relay = relaySnapshot;
        if (!relay?.devices) throw Error('Relay indisponivel');
        for (const phone of relay.devices) {
          const directIndex = devices.findIndex(d => d.id === phone.id);
          if (directIndex >= 0 && devices[directIndex].paired && devices[directIndex].reachable) continue;
          if (directIndex >= 0) devices.splice(directIndex, 1);
          devices.push({ ...phone, id: 'x99:' + phone.id, via: 'X99', canShareFiles: true });
        }
      } catch { error = 'Ponte X99 indisponivel'; }
    }
    return { devices, error, updatedAt: Date.now() / 1000 };
  }
  if (!/^[a-zA-Z0-9_]{1,128}$/.test(id || '')) throw Error('Dispositivo invalido');
  const path = root + '/devices/' + id;
  const p = await properties(path, iface);
  if (!p.isReachable || !p.isPaired) throw Error('Celular desconectado ou nao pareado');
  if (command === 'ring') await call(path + '/findmyphone', iface + '.findmyphone', 'ring');
  else if (command === 'share') {
    const value = process.argv[4] || '';
    const url = new URL(value);
    if (!['https:', 'http:', 'file:'].includes(url.protocol) || url.username || url.password) throw Error('Link invalido');
    if (url.protocol === 'file:' && (url.hostname || !fs.statSync(url).isFile())) throw Error('Arquivo invalido');
    await call(path + '/share', iface + '.share', 'shareUrl', 's', [url.href]);
  } else throw Error('Comando desconhecido');
  return { ok: true };
}
main().then(value => finish(value)).catch(error => finish(relayFallback(String(error.message).slice(0, 300)), 1));
