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


def windows():
    return os.name == 'nt'


def receiver():
    spec = importlib.util.spec_from_file_location('windows_receiver', Path(__file__).with_name('windows-receiver.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


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
    return BASE/('bin/lan-mouse.exe' if windows() else 'lan-mouse')


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
    if windows():
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
    if not 1 <= len(peers) <= 2 or len({p['id'] for p in peers}) != len(peers):
        raise ValueError('One or two distinct peers are required')
    if not {p['position'] for p in peers} <= {'left', 'right'} or len({p['position'] for p in peers}) != len(peers):
        raise ValueError('Only one peer per edge is allowed')
    if len({p['fingerprint'].lower() for p in peers}) != len(peers):
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


def profile_digest():
    return hashlib.sha256(json.dumps(load(BASE/'profile.json'), sort_keys=True, separators=(',', ':')).encode()).hexdigest()


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
    elif windows():
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
    if windows():
        text = powershell("$p=Get-CimInstance Win32_Process -Filter "+psquote('ProcessId='+str(pid))+"; "
                          +"if($p -and $p.ExecutablePath -eq "+psquote(binary())
                          +" -and $p.CommandLine.Contains("+psquote(BASE/'config.toml')+")){"
                          +"$p.CreationDate.ToUniversalTime().ToString('o')}")
        return text.strip() or None
    return None


def powershell(script):
    r = subprocess.run(['powershell', '-NoProfile', '-EncodedCommand',
                        base64.b64encode(script.encode('utf-16le')).decode()], capture_output=True, text=True, timeout=20,
                       creationflags=subprocess.CREATE_NO_WINDOW if windows() else 0)
    if r.returncode:
        raise RuntimeError(r.stderr[-800:])
    return r.stdout


def psquote(value):
    return "'"+str(value).replace("'", "''")+"'"


def stop():
    if sys.platform == 'darwin':
        session_agent().stop(AGENT, command())
    if windows():
        with receiver().lifecycle_lock(BASE):
            # Fence respawn before stopping the supervisor. Enumerate AFTER task
            # termination so a child created just before the fence cannot escape.
            save(BASE/'receiver-control.json', {})
            state = load(BASE/'session.json')
            state['receiver'] = dict(state='stopping', restarts=state.get('receiver', {}).get('restarts', 0))
            save(BASE/'session.json', state)
            try:
                powershell("$ErrorActionPreference='Stop'; "
                           +"if(Get-ScheduledTask -TaskName "+psquote(TASK)+" -ErrorAction SilentlyContinue){"
                           +"Stop-ScheduledTask -TaskName "+psquote(TASK)+"}; "
                           +"$owned=@(Get-CimInstance Win32_Process -Filter \"Name='lan-mouse.exe'\" | Where-Object { $_.ExecutablePath -eq "
                           +psquote(binary())+" -and $_.CommandLine.Contains("+psquote(BASE/'config.toml')+") }); "
                           +"foreach($p in $owned){$live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ProcessId); "
                           +"if($live -and $live.CreationDate -eq $p.CreationDate -and $live.ExecutablePath -eq $p.ExecutablePath){"
                           +"Stop-Process -Id $p.ProcessId -Force; "
                           +"if(Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue){Wait-Process -Id $p.ProcessId -Timeout 5}}}; "
                           +"$remaining=@(Get-CimInstance Win32_Process -Filter \"Name='lan-mouse.exe'\" | Where-Object { $_.ExecutablePath -eq "
                           +psquote(binary())+" -and $_.CommandLine.Contains("+psquote(BASE/'config.toml')+") }); "
                           +"if($remaining.Count){throw 'Owned input child still running'}")
            except Exception:
                state['receiver'].update(state='failed', error='stop_unconfirmed')
                save(BASE/'session.json', state)
                raise
            save(BASE/'session.json', dict(receiver=dict(state='stopped', restarts=0)))
        return dict(ok=True, running=False)
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


def supervise(bootstrap=False, generation=None):
    sys.exit(receiver().Supervisor(sys.modules[__name__], generation, bootstrap).run())


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
    if windows():
        with receiver().lifecycle_lock(BASE):
            write_config(False)
            generation = receiver().begin(sys.modules[__name__], bootstrap)
            pythonw = Path(sys.executable).with_name('pythonw.exe')
            args = subprocess.list2cmdline(['-I', str(Path(__file__).resolve()), '--supervise',
                                           '--generation', generation]+(['--bootstrap'] if bootstrap else []))
            powershell("$ErrorActionPreference='Stop'; $a=New-ScheduledTaskAction -Execute "+psquote(pythonw)
                       +" -Argument "+psquote(args)+" -WorkingDirectory "+psquote(BASE)+"; "
                       +"$p=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited; "
                       +"$s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero); "
                       +"Register-ScheduledTask -TaskName "+psquote(TASK)+" -Action $a -Principal $p -Settings $s -Force | Out-Null; "
                       +"Start-ScheduledTask -TaskName "+psquote(TASK))
    elif sys.platform == 'darwin':
        write_config(False)
        pid = session_agent().start(AGENT, command(bootstrap), BASE, BASE/'daemon.log', dict(RUST_LOG='info'))
        save(BASE/'session.json', dict(pid=pid, identity=process_identity(pid), bootstrap=bootstrap, profileDigest=profile_digest()))
    else:
        write_config(False)
        with (BASE/'daemon.log').open('a') as log:
            child = subprocess.Popen(command(bootstrap), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     env=desktop_env(), start_new_session=True)
        time.sleep(.15)
        save(BASE/'session.json', dict(pid=child.pid, identity=process_identity(child.pid), bootstrap=bootstrap, profileDigest=profile_digest()))
    deadline = time.monotonic()+8
    while time.monotonic() < deadline:
        current = status(starting_generation=generation) if windows() else status()
        if current['running']:
            if (BASE/'identity.pem').exists():
                (BASE/'identity.pem').chmod(0o600)
            return current
        time.sleep(.2)
    raise RuntimeError('Lan Mouse failed to start; inspect its private runtime log')


def status(starting_generation=None):
    token = BASE/'cache/lan-mouse/remote-desktop.token'
    if sys.platform.startswith('linux') and token.is_file():
        token.chmod(0o600)
    result = dict(ok=True, installed=binary().is_file(), running=False,
                  capture=False, emulation=False, fingerprint=fingerprint(), peers=[])
    state = load(BASE/'session.json')
    if windows():
        result['receiver'] = state.get('receiver', dict(state='unknown', restarts=0))
    try:
        events = ipc()
    except OSError:
        return result
    latest = load(BASE/'session.json')
    if windows() and starting_generation is not None:
        control = load(BASE/'receiver-control.json')
        if any(s.get('generation') != starting_generation for s in (state, latest, control)):
            raise RuntimeError('Receiver startup was cancelled or changed')
        initial = (not state.get('pid') and not state.get('identity') and
                   state.get('receiver') == dict(state='starting', restarts=0))
        if initial and latest.get('receiver') in (dict(state='starting', restarts=0), dict(state='ready', restarts=0)):
            if latest.get('pid'):
                if not latest.get('identity') or process_identity(latest['pid']) != latest['identity']:
                    raise RuntimeError('Lan Mouse process ownership changed')
            elif latest.get('receiver', {}).get('state') != 'starting' or latest.get('identity'):
                raise RuntimeError('Lan Mouse process ownership changed')
            # Only this start's pre-PID publication may be incomplete. Discard
            # its IPC data and observe again within start's existing deadline.
            return result
    if windows() and any(latest.get(k) != state.get(k) for k in ('pid', 'generation', 'identity')):
        raise RuntimeError('Receiver session changed during status')
    state = latest
    if windows():
        result['receiver'] = state.get('receiver', dict(state='unknown', restarts=0))
    if not state.get('pid'):
        raise RuntimeError('Another Lan Mouse instance owns the local IPC socket')
    if not state.get('identity') or process_identity(state['pid']) != state['identity']:
        raise RuntimeError('Lan Mouse process ownership changed')
    result['running'] = True
    # A legacy session has no launch evidence. Reading a newly written profile
    # alone must never confirm what an older running daemon actually loaded.
    result['profileDigest'] = state.get('profileDigest')
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
            result['peers'] = [dict(id=ident(c), position=c['pos'].lower(), active=s['active'], alive=s['alive'], handle=h)
                               for h, c, s in event['Enumerate']]
    return result


def windows_activation(active):
    helper = receiver()
    observed = load(BASE/'session.json')
    current = status()
    with helper.lifecycle_lock(BASE):
        control = load(BASE/'receiver-control.json')
        state = load(BASE/'session.json')
        if ((state.get('pid'), state.get('generation')) != (observed.get('pid'), observed.get('generation')) or
                not control.get('generation') or control['generation'] != state.get('generation')):
            raise RuntimeError('Receiver session is not current')
        if helper.protected(sys.modules[__name__]) != control.get('protected'):
            raise RuntimeError('Receiver protected state changed')
        if not active:
            control['active'] = False
            save(BASE/'receiver-control.json', control)
        if not active and not current['running']:
            return current
        if active and not (current['capture'] and current['emulation'] and
                           current['receiver']['state'] == 'ready'):
            raise RuntimeError('Input permissions/backends or receiver are not ready')
        profile = validate_profile(load(BASE/'profile.json'))
        if not helper.exact_peers(current, profile):
            raise RuntimeError('Native peers differ from configured profile')
        # Save intent before IPC: a lost reply may still mean active input. The
        # stop fence clears this intent even if recovery is already underway.
        control['active'] = active
        save(BASE/'receiver-control.json', control)
        helper.activate(sys.modules[__name__], control, state, current['peers'], active)
    return status()


def main(request):
    BASE.mkdir(parents=True, mode=0o700, exist_ok=True)
    action = request.get('action', 'status')
    if action == 'status':
        return status()
    if action == 'configure':
        if windows():
            with receiver().lifecycle_lock(BASE):
                save(BASE/'profile.json', validate_profile(request['profile']))
                write_config(False)
            return dict(ok=True)
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
        if windows():
            return windows_activation(action == 'activate')
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
        generation = sys.argv[sys.argv.index('--generation')+1] if '--generation' in sys.argv else None
        supervise('--bootstrap' in sys.argv, generation)
    else:
        try:
            print(json.dumps(main(json.load(sys.stdin))))
        except Exception as error:
            print(json.dumps(dict(ok=False, error=str(error))))
            sys.exit(1)
