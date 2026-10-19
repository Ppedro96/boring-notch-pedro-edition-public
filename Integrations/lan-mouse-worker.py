#!/usr/bin/env python3
"""Owned Lan Mouse daemon and local IPC. Private peer profiles never leave runtime."""
import base64
import hashlib
import ipaddress
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import ssl
import subprocess
import sys
import time
import uuid

BASE = Path.home()/'.local/share'/('pedro-notch' if sys.platform == 'darwin' else 'insight-notch')/'lan-mouse'
TASK = 'InsightNotchLanMouse'
AGENT = 'local.insight-notch.lan-mouse'


def session_agent():
    spec = importlib.util.spec_from_file_location('macos_session_agent', Path(__file__).with_name('macos-session-agent.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def save(path, value):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    temp = path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
    temp.write_text(json.dumps(value), encoding='utf-8')
    temp.chmod(0o600)
    temp.replace(path)


def load(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def binary():
    if sys.platform == 'darwin':
        return Path('/Applications/Lan Mouse.app/Contents/MacOS/lan-mouse')
    return BASE/('bin/lan-mouse.exe' if os.name == 'nt' else 'lan-mouse')


def desktop_env():
    env = dict(os.environ, RUST_LOG='info')
    if sys.platform.startswith('linux'):
        env.update(XDG_RUNTIME_DIR='/run/user/'+str(os.getuid()),
                   XDG_CACHE_HOME=str(BASE/'cache'),
                   DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/'+str(os.getuid())+'/bus')
        for process in Path('/proc').iterdir():
            try:
                if process.stat().st_uid != os.getuid() or (process/'comm').read_text().strip() != 'plasmashell':
                    continue
                desktop = dict(item.split('=', 1) for item in (process/'environ').read_bytes().decode().split('\0') if '=' in item)
                for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'XAUTHORITY', 'DBUS_SESSION_BUS_ADDRESS',
                            'XDG_RUNTIME_DIR', 'XDG_SESSION_TYPE', 'XDG_CURRENT_DESKTOP'):
                    if key in desktop:
                        env[key] = desktop[key]
                break
            except OSError:
                continue
    return env


def prepare_permission_cache():
    if not sys.platform.startswith('linux'):
        return
    # Upstream rotates a single-use restore token at each successful session.
    # Keep it in private persistent runtime storage, outside disposable desktop caches.
    target = BASE/'cache/lan-mouse/remote-desktop.token'
    target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    (BASE/'cache').chmod(0o700)
    target.parent.chmod(0o700)
    original = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home()/'.cache')))/'lan-mouse/remote-desktop.token'
    if not target.exists() and original.is_file() and not original.is_symlink():
        shutil.copyfile(original, target)
    if target.is_file():
        target.chmod(0o600)


def ipc(request='Sync', timeout=1.0):
    env = desktop_env()
    if os.name == 'nt':
        connection = socket.create_connection(('127.0.0.1', 5252), timeout=timeout)
    else:
        path = (Path.home()/'Library/Caches' if sys.platform == 'darwin'
                else Path(env['XDG_RUNTIME_DIR']))/'lan-mouse-socket.sock'
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(timeout)
        connection.connect(str(path))
    events = []
    with connection:
        connection.sendall((json.dumps(request)+'\n').encode())
        pending = b''
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            connection.settimeout(max(.01, deadline-time.monotonic()))
            try:
                data = connection.recv(65536)
            except socket.timeout:
                break
            if not data:
                break
            pending += data
            if len(pending) > 1024*1024:
                raise ValueError('IPC response too large')
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                events.append(json.loads(line))
    return events


def fingerprint():
    try:
        pem = (BASE/'identity.pem').read_text(encoding='utf-8')
        cert = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pem, re.S).group()
        digest = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest()
        return ':'.join(digest[i:i+2] for i in range(0, len(digest), 2))
    except (OSError, AttributeError, ValueError):
        return None


def validate_profile(profile):
    peers = profile.get('peers', [])
    if len(peers) != 2 or len({p['id'] for p in peers}) != 2:
        raise ValueError('Exactly two distinct peers are required')
    if {p['position'] for p in peers} != {'left', 'right'}:
        raise ValueError('Only one peer per edge is allowed')
    if len({p['fingerprint'].lower() for p in peers}) != 2:
        raise ValueError('Peer certificates must be distinct')
    for key, values in [('capture_backend', ('layer-shell', 'input-capture-portal')),
                        ('emulation_backend', ('libei', 'xdp'))]:
        if key in profile and profile[key] not in values:
            raise ValueError('Unsupported input backend')
    addresses = set()
    for peer in peers:
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,40}', peer['id']):
            raise ValueError('Invalid peer id')
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2}', peer['fingerprint']):
            raise ValueError('Invalid certificate fingerprint')
        ips = peer['ips']
        if not 1 <= len(ips) <= 4:
            raise ValueError('Invalid peer addresses')
        for address in ips:
            ip = ipaddress.ip_address(address)
            if ip.is_unspecified or ip.is_multicast or ip.is_loopback:
                raise ValueError('Invalid peer address')
            if ip in addresses:
                raise ValueError('Peer addresses must be distinct')
            addresses.add(ip)
    return profile


def config_text(profile=None, active=False):
    # JSON strings are valid TOML basic strings for these validated values/paths.
    q = json.dumps
    lines = ['port = 4242', 'cert_path = '+q(str(BASE/'identity.pem')),
             'release_bind = ["KeyLeftCtrl", "KeyLeftAlt", "KeyHome"]']
    for key in ('capture_backend', 'emulation_backend'):
        if key in (profile or {}):
            lines.append(key+' = '+q(profile[key]))
    for peer in (profile or {}).get('peers', []):
        lines.extend(['', '[[clients]]',
                      'ips = '+q(peer['ips']), 'port = 4242',
                      'position = '+q(peer['position']),
                      'activate_on_startup = '+str(bool(active)).lower()])
    lines.extend(['', '[authorized_fingerprints]'])
    for peer in (profile or {}).get('peers', []):
        lines.append(q(peer['fingerprint'])+' = '+q(peer['id']))
    return '\n'.join(lines)+'\n'


def write_config(active=False):
    path = BASE/'config.toml'
    path.write_text(config_text(load(BASE/'profile.json'), active), encoding='utf-8')
    path.chmod(0o600)


def command(bootstrap=False):
    result = [str(binary()), '--config', str(BASE/'config.toml'), '--cert-path', str(BASE/'identity.pem')]
    if bootstrap:
        result += ['--capture-backend', 'dummy', '--emulation-backend', 'dummy']
    elif sys.platform == 'darwin':
        result += ['--capture-backend', 'mac-os', '--emulation-backend', 'mac-os']
    elif os.name == 'nt':
        result += ['--capture-backend', 'windows', '--emulation-backend', 'windows']
    return result+['daemon']


def process_identity(pid):
    if not isinstance(pid, int) or pid <= 1:
        return None
    if sys.platform.startswith('linux'):
        try:
            proc = Path('/proc')/str(pid)
            args = (proc/'cmdline').read_bytes().split(b'\0')
            if str(binary()).encode() not in args or str(BASE/'config.toml').encode() not in args:
                return None
            return (proc/'stat').read_text().rsplit(')', 1)[1].split()[19]
        except OSError:
            return None
    if sys.platform == 'darwin':
        r = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=', '-o', 'command='], capture_output=True, text=True)
        if str(binary()) not in r.stdout or str(BASE/'config.toml') not in r.stdout:
            return None
        return r.stdout[:24]
    if os.name == 'nt':
        text = powershell("$p=Get-CimInstance Win32_Process -Filter "+psquote('ProcessId='+str(pid))+"; "
                          +"if($p -and $p.ExecutablePath -eq "+psquote(binary())
                          +" -and $p.CommandLine.Contains("+psquote(BASE/'config.toml')+")){"
                          +"$p.CreationDate.ToUniversalTime().ToString('o')}")
        return text.strip() or None
    return None


def powershell(script):
    r = subprocess.run(['powershell', '-NoProfile', '-EncodedCommand',
                        base64.b64encode(script.encode('utf-16le')).decode()], capture_output=True, text=True, timeout=20)
    if r.returncode:
        raise RuntimeError(r.stderr[-800:])
    return r.stdout


def psquote(value):
    return "'"+str(value).replace("'", "''")+"'"


def stop():
    if sys.platform == 'darwin':
        session_agent().stop(AGENT, command())
    if os.name == 'nt':
        # Task termination alone leaves its native child alive. Match both executable and config.
        powershell("$owned=@(Get-CimInstance Win32_Process -Filter \"Name='lan-mouse.exe'\" | Where-Object { $_.ExecutablePath -eq "
                   +psquote(binary())+" -and $_.CommandLine.Contains("+psquote(BASE/'config.toml')+") }); "
                   +"Stop-ScheduledTask -TaskName "+psquote(TASK)+" -ErrorAction SilentlyContinue; "
                   +"foreach($p in $owned){$live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ProcessId); "
                   +"if($live -and $live.CreationDate -eq $p.CreationDate -and $live.ExecutablePath -eq $p.ExecutablePath){"
                   +"Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue}}; exit 0")
    else:
        state = load(BASE/'session.json')
        pid = state.get('pid')
        if state.get('identity') and process_identity(pid) == state['identity']:
            os.kill(pid, signal.SIGTERM)
            for _ in range(30):
                if process_identity(pid) != state['identity']:
                    break
                time.sleep(.1)
            else:
                os.kill(pid, signal.SIGKILL)
    save(BASE/'session.json', {})
    return dict(ok=True, running=False)


def supervise(bootstrap=False):
    with (BASE/'daemon.log').open('a', encoding='utf-8') as log:
        child = subprocess.Popen(command(bootstrap), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 creationflags=subprocess.CREATE_NO_WINDOW, env=desktop_env(), cwd=binary().parent)
        save(BASE/'session.json', dict(pid=child.pid, identity=process_identity(child.pid), bootstrap=bootstrap))
        sys.exit(child.wait())


def start(bootstrap=False):
    old = load(BASE/'session.json')
    current = status()
    if current['running']:
        if old.get('bootstrap', False) != bootstrap:
            stop()
        else:
            return current
    else:
        stop()
    if not binary().is_file():
        raise ValueError('Lan Mouse is not installed')
    prepare_permission_cache()
    write_config(False)
    if os.name == 'nt':
        pythonw = Path(sys.executable).with_name('pythonw.exe')
        args = subprocess.list2cmdline(['-I', str(Path(__file__).resolve()), '--supervise']+(['--bootstrap'] if bootstrap else []))
        powershell("$ErrorActionPreference='Stop'; $a=New-ScheduledTaskAction -Execute "+psquote(pythonw)
                   +" -Argument "+psquote(args)+" -WorkingDirectory "+psquote(BASE)+"; "
                   +"$p=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited; "
                   +"$s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero); "
                   +"Register-ScheduledTask -TaskName "+psquote(TASK)+" -Action $a -Principal $p -Settings $s -Force | Out-Null; "
                   +"Start-ScheduledTask -TaskName "+psquote(TASK))
    elif sys.platform == 'darwin':
        pid = session_agent().start(AGENT, command(bootstrap), BASE, BASE/'daemon.log', dict(RUST_LOG='info'))
        save(BASE/'session.json', dict(pid=pid, identity=process_identity(pid), bootstrap=bootstrap))
    else:
        with (BASE/'daemon.log').open('a') as log:
            child = subprocess.Popen(command(bootstrap), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     env=desktop_env(), start_new_session=True)
        time.sleep(.15)
        save(BASE/'session.json', dict(pid=child.pid, identity=process_identity(child.pid), bootstrap=bootstrap))
    deadline = time.monotonic()+8
    while time.monotonic() < deadline:
        current = status()
        if current['running']:
            if (BASE/'identity.pem').exists():
                (BASE/'identity.pem').chmod(0o600)
            return current
        time.sleep(.2)
    raise RuntimeError('Lan Mouse failed to start; inspect its private runtime log')


def status():
    token = BASE/'cache/lan-mouse/remote-desktop.token'
    if sys.platform.startswith('linux') and token.is_file():
        token.chmod(0o600)
    result = dict(ok=True, installed=binary().is_file(), running=False,
                  capture=False, emulation=False, fingerprint=fingerprint(), peers=[])
    try:
        events = ipc()
    except OSError:
        return result
    state = load(BASE/'session.json')
    if not state.get('pid'):
        raise RuntimeError('Another Lan Mouse instance owns the local IPC socket')
    if not state.get('identity') or process_identity(state['pid']) != state['identity']:
        raise RuntimeError('Lan Mouse process ownership changed')
    result['running'] = True
    for event in events:
        if not isinstance(event, dict):
            continue
        if 'CaptureStatus' in event:
            result['capture'] = event['CaptureStatus'] == 'Enabled'
        if 'EmulationStatus' in event:
            result['emulation'] = event['EmulationStatus'] == 'Enabled'
        if 'PublicKeyFingerprint' in event:
            result['fingerprint'] = event['PublicKeyFingerprint']
        if 'Enumerate' in event:
            profiles = load(BASE/'profile.json').get('peers', [])
            def ident(config):
                return next((p['id'] for p in profiles if set(p['ips']) & set(config['fix_ips'])), config['hostname'])
            result['peers'] = [dict(id=ident(c), active=s['active'], alive=s['alive'], handle=h)
                               for h, c, s in event['Enumerate']]
    return result


def main(request):
    BASE.mkdir(parents=True, mode=0o700, exist_ok=True)
    action = request.get('action', 'status')
    if action == 'status':
        return status()
    if action == 'configure':
        save(BASE/'profile.json', validate_profile(request['profile']))
        write_config(False)
        return dict(ok=True)
    if action == 'bootstrap':
        return start(True)
    if action == 'start':
        return start()
    if action == 'stop':
        return stop()
    if action == 'retry':
        ipc('EnableEmulation', .15)
        ipc('EnableCapture', .15)
        return status()
    if action in ('activate', 'deactivate'):
        current = status()
        active = action == 'activate'
        if active and not (current['capture'] and current['emulation']):
            raise RuntimeError('Input permissions/backends are not ready')
        for peer in current['peers']:
            ipc({'Activate': [peer['handle'], active]}, .15)
        return status()
    raise ValueError('Invalid action')


if __name__ == '__main__':
    if '--supervise' in sys.argv:
        supervise('--bootstrap' in sys.argv)
    else:
        try:
            print(json.dumps(main(json.load(sys.stdin))))
        except Exception as error:
            print(json.dumps(dict(ok=False, error=str(error))))
            sys.exit(1)
