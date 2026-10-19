#!/usr/bin/env python3
"""Authorized ADB discovery and on-demand scrcpy; never enables TCP/5555 or pairs silently."""
import base64
import fcntl
import json
import importlib.util
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path.home() / '.local/share/pedro-notch'
ADB = '/opt/homebrew/bin/adb'
SCRCPY = '/Applications/scrcpy.app/Contents/MacOS/scrcpy'
PROFILES = {
    'demo_s25': ('S25 Ultra', 'SM-S938'),
    'demo_fold': ('Z Fold6', 'SM-F956'),
    'demo_tablet': ('Tab S8+', 'SM-X806'),
    'demo_s23': ('S23 Ultra', 'SM-S918'),
}
STATE = ROOT / 'scrcpy-devices.json'


def run(args, env=None, timeout=6):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env).stdout.strip()


def devices(text):
    return [match[1] for line in text.splitlines()
            if (match := re.match(r'^(.*?)\s+device(?:\s|$)', line))]


def services(text):
    found = []
    # Bonjour suffixes such as " (2)" are part of the instance, not extra fields.
    for line in text.splitlines():
        match = re.match(r'^(.+?)\s+_adb-tls-connect\._tcp\s+([0-9.]+:[0-9]+)\s*$', line)
        if match:
            found.append((match[1], match[2]))
    return found


def tracked_services(text):
    # adb 37 may return an empty legacy `mdns services` table. Use its current API.
    found = []
    for block in re.findall(r'service\s*\{([^{}]+)\}', text):
        def field(key):
            match = re.search(r'\b' + key + r':\s*"([^"\n]+)"', block)
            return match[1] if match else ''
        port = re.search(r'\bport:\s*(\d+)', block)
        if field('service') == '_adb-tls-connect._tcp' and re.fullmatch(r'[0-9.]+', field('ipv4')) and port:
            entry = (field('instance'), field('ipv4') + ':' + port[1])
            if entry not in found:
                found.append(entry)
    return found


def mdns_services():
    result = services(run([ADB, 'mdns', 'services']))
    if result:
        return result
    proc = subprocess.Popen([ADB, 'mdns', 'track-services', '--proto-text'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        output, _ = proc.communicate(timeout=1.5)
    except subprocess.TimeoutExpired:
        proc.terminate()
        output, _ = proc.communicate(timeout=2)
    return tracked_services(output)


def load():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save(value):
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=ROOT, delete=False) as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        tmp = Path(handle.name)
    tmp.chmod(0o600)
    tmp.replace(STATE)


def discover():
    state = load()
    connected = []
    seen = set()
    serials = devices(run([ADB, 'devices']))
    preferred = {entry.get('transport') for entry in state.values()}
    serials.sort(key=lambda serial: serial not in preferred)
    for serial in serials:
        try:
            hardware = run([ADB, '-s', serial, 'shell', 'getprop', 'ro.serialno'], timeout=3)
            if not hardware or hardware in seen:
                continue
            model = run([ADB, '-s', serial, 'shell', 'getprop', 'ro.product.model'], timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            continue  # A stale transport must not prevent the remaining phones from working.
        for ident, (name, prefix) in PROFILES.items():
            if model.startswith(prefix):
                entry = {'name': name, 'model': model, 'hardware': hardware, 'transport': serial}
                state[ident] = entry
                connected.append((ident, entry))
                seen.add(hardware)
                break
    if connected:
        save(state)
    return connected


def reconnect():
    run([ADB, 'start-server'])
    state = load()
    allowed = [entry.get('hardware', '') for entry in state.values() if entry.get('hardware')]
    # TLS discovery handles changing IP/port; only already learned devices are retried.
    online = set(devices(run([ADB, 'devices'])))
    # A suffix rename must not cause an extra connection to an already online device.
    for name, endpoint in mdns_services():
        hardware = next((serial for serial in allowed if name.startswith('adb-' + serial + '-')), None)
        if not hardware:
            continue
        if endpoint in online or any(serial.startswith('adb-' + hardware + '-') for serial in online):
            continue
        try:
            run([ADB, 'connect', endpoint], timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            continue

    return discover()


def available_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def native_window(ident,package,selected):
    try:
        spec=importlib.util.spec_from_file_location('android_window',Path(__file__).with_name('android-window.py'))
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        return module.bundle(ident,PROFILES[ident][0],package,selected)
    except Exception as error:
        print('Janela nativa indisponível: '+str(error),flush=True)
        return SCRCPY,None,(package+' · ' if package else '')+PROFILES[ident][0]

def mirror(ident, package=None):
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (ROOT / ('scrcpy-' + ident + ('-' + package if package else '') + '.lock')).open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            tunnel = None
            env = dict(os.environ, PATH='/opt/homebrew/bin:/usr/bin:/bin',
                       SCRCPY_SERVER_PATH='/Applications/scrcpy.app/Contents/Resources/scrcpy-server')
            args = [SCRCPY, '--max-size=1600', '--max-fps=30', '--video-bit-rate=6M',
                    '--no-audio', '--no-clipboard-autosync', '--window-title=' + PROFILES[ident][0] + ' · Insight Notch']
            if package:
                args += ['--new-display=1280x960', '--flex-display', '--keep-active', '--start-app=' + package,
                         '--window-title=' + package + ' · ' + PROFILES[ident][0]]
            try:
                selected = next((item for key, item in reconnect() if key == ident), None)
                if selected:
                    args += ['--serial=' + selected['transport']]
                elif ident == 'demo_s23':
                    # Loopback-only SSH forwards reuse X99's existing authorization; no daemon restart.
                    adb_port, video_port = available_port(), available_port()
                    tunnel = subprocess.Popen(['/usr/bin/ssh', '-NT', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                        '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2',
                        '-L', f'127.0.0.1:{adb_port}:127.0.0.1:5037',
                        '-L', f'127.0.0.1:{video_port}:127.0.0.1:{video_port}', 'x99'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    env['ADB_SERVER_SOCKET'] = f'tcp:127.0.0.1:{adb_port}'
                    remote = []
                    for _ in range(15):
                        if tunnel.poll() is not None:
                            break
                        try:
                            remote = devices(run([ADB, 'devices'], env=env, timeout=2))
                            if remote:
                                break
                        except subprocess.TimeoutExpired:
                            pass
                        time.sleep(.2)
                    serial = next((s for s in remote if run([ADB, '-s', s, 'shell', 'getprop', 'ro.serialno'], env=env) == 'DEMO_S23'), None)
                    if not serial:
                        raise RuntimeError('S23 indisponível no X99')
                    args += ['--serial=' + serial, '--force-adb-forward', '--port=' + str(video_port)]
                else:
                    raise RuntimeError('Aparelho ainda não pareado/conectado ao ADB deste Mac')
                binary,resources,title=native_window(ident,package,selected)
                args[0]=binary
                args=[arg for arg in args if not arg.startswith('--window-title=')]+['--window-title='+title]
                if resources:env['SCRCPY_ICON_DIR']=str(resources)
                env['SDL_APP_NAME']=title
                env['SDL_MAC_BACKGROUND_APP']='0'
                started = time.monotonic()
                proc = subprocess.Popen(args, env=env)
                result = proc.wait()
                if result == 0:
                    return  # A normal window close must never reopen it.
                if time.monotonic() - started > 10:
                    deadline = time.monotonic() + 120
            except (subprocess.TimeoutExpired, RuntimeError) as error:
                print(str(error), flush=True)
            finally:
                if tunnel:
                    tunnel.terminate()
                    try:
                        tunnel.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        tunnel.kill()
            time.sleep(4)


def app_packages(text):
    return sorted(set(re.findall(r'^\s*([A-Za-z][A-Za-z0-9_.]+)/[^\s]+$', text, re.M)))

def app_labels(text):
    return {package: label.strip() for label, package in re.findall(r'^\s*[*-] (.+?)\s{2,}([A-Za-z][A-Za-z0-9_.]+)\s*$', text, re.M)}

def x99_apps():
    # Reuse X99's existing ADB authorization and identify the S23 by hardware serial.
    code = """import subprocess,re,json
from pathlib import Path
run=lambda args:subprocess.run(args,capture_output=True,text=True,timeout=20).stdout
serials=[m[1] for line in run(['adb','devices']).splitlines() if (m:=re.match(r'^(.*?)\\s+device(?:\\s|$)',line))]
serial=next((s for s in serials if run(['adb','-s',s,'shell','getprop','ro.serialno']).strip()=='DEMO_S23'),None)
if not serial:raise ValueError('S23 indisponível no X99')
output=run(['adb','-s',serial,'shell','cmd','package','query-activities','--brief','-a','android.intent.action.MAIN','-c','android.intent.category.LAUNCHER'])
listing=subprocess.run(['scrcpy','--serial='+serial,'--list-apps'],capture_output=True,text=True,timeout=30)
print(json.dumps(dict(output=output,listing=listing.stdout+listing.stderr)))
"""
    encoded=base64.b64encode(code.encode()).decode()
    result=run(['/usr/bin/ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','x99',
                'python3 -c "import base64;exec(base64.b64decode(\''+encoded+'\'))"'],timeout=50)
    if not result:raise ValueError('Não foi possível listar os apps do S23 no X99')
    return json.loads(result)

def main():
    command = sys.argv[1] if len(sys.argv) > 1 else 'list'
    if command in ('list', 'reconnect'):
        print(json.dumps({'devices': reconnect()}, ensure_ascii=False))
    elif command in ('open', 'worker', 'apps', 'app'):
        ident = sys.argv[2].removeprefix('x99:') if hasattr(str, 'removeprefix') else sys.argv[2].replace('x99:', '', 1)
        if ident not in PROFILES:
            raise ValueError('Aparelho não configurado')
        package = sys.argv[3] if len(sys.argv) > 3 else None
        if package and not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+', package):
            raise ValueError('Pacote Android inválido')
        if command == 'apps':
            selected = next((item for key, item in reconnect() if key == ident), None)
            if selected:
                output = run([ADB, '-s', selected['transport'], 'shell', 'cmd', 'package', 'query-activities', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER'], timeout=20)
            elif ident == 'demo_s23':
                remote_apps = x99_apps()
                output = remote_apps['output']
            else:
                raise ValueError('Aparelho desconectado do ADB')
            packages = app_packages(output)
            labels = app_labels(remote_apps['listing']) if not selected else {}
            if selected:
                env = dict(os.environ, PATH='/opt/homebrew/bin:/usr/bin:/bin', SCRCPY_SERVER_PATH='/Applications/scrcpy.app/Contents/Resources/scrcpy-server')
                try:
                    listing = run([SCRCPY, '--serial=' + selected['transport'], '--list-apps'], env=env, timeout=25)
                    labels = app_labels(listing)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            apps = [{'id': p, 'name': labels.get(p, p.removeprefix('com.').removeprefix('org.'))} for p in packages]
            apps.sort(key=lambda app: app['name'].casefold())
            print(json.dumps({'ok': True, 'apps': apps}, ensure_ascii=False))
            return
        if command == 'app' and not package:
            raise ValueError('Escolha um aplicativo')
        if command == 'worker':
            mirror(ident, package)
            return
        if ident != 'demo_s23' and not any(key == ident for key, _ in reconnect()):
            print(json.dumps({'ok': False, 'error': 'Ative a depuração Wi-Fi e pareie este aparelho com o Mac'}))
            return
        if command == 'app' and ident == 'demo_tablet':
            selected = next((entry for key, entry in discover() if key == ident), None)
            if selected:
                power = run([ADB, '-s', selected['transport'], 'shell', 'dumpsys', 'power'], timeout=4)
                if re.search(r'mWakefulness=(Dozing|Asleep)', power):
                    print(json.dumps({'ok': False, 'error': 'Abra a capa e desbloqueie o tablet para abrir apps em janelas'}, ensure_ascii=False))
                    return
        ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (ROOT / ('scrcpy-' + ident + '.log')).open('a') as log:
            subprocess.Popen(['/usr/bin/python3', str(Path(__file__).resolve()), 'worker', ident] + ([package] if package else []),
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        print(json.dumps({'ok': True}))
    else:
        raise ValueError('Comando inválido')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
