#!/usr/bin/env python3
"""Coordinate bidirectional input with the existing Mesa lifecycle, with rollback."""
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
from pathlib import Path
import subprocess
import time
import uuid

BASE = Path.home()/'.local/share/pedro-notch/lan-mouse'
HOSTS = ('mac', 'x99', 'alienware')
REMOTE_WORKER = '.local/share/insight-notch/lan-mouse-worker.py'


def enabled():
    try:
        return json.loads((BASE/'mesh.json').read_text()).get('enabled') is True
    except (OSError, ValueError):
        return False


def rpc(host, request):
    if host == 'mac':
        args = ['/usr/bin/python3', str(Path(__file__).with_name('lan-mouse-worker.py'))]
    else:
        code = base64.b64encode(('import runpy;from pathlib import Path;runpy.run_path(str(Path.home()/'
                                 +repr(REMOTE_WORKER)+"),run_name='__main__')").encode()).decode()
        args = ['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host,
                ('python' if host == 'alienware' else 'python3')+' -c "import base64;exec(base64.b64decode(\''+code+'\'))"']
    result = subprocess.run(args, input=json.dumps(request), capture_output=True, text=True, timeout=30)
    try:
        value = json.loads(result.stdout.strip().lstrip('\ufeff'))
    except ValueError:
        raise RuntimeError('Input worker unavailable: '+host)
    if not value.get('ok'):
        raise RuntimeError(value.get('error', 'Input worker failed'))
    return value


def all_hosts(action):
    def run(host):
        try:
            return host, rpc(host, dict(action=action))
        except Exception as error:
            return host, dict(ok=False, running=False, error=str(error))
    with ThreadPoolExecutor(max_workers=3) as pool:
        return dict(pool.map(run, HOSTS))


def ready(value):
    return value.get('ok') and value.get('running') and value.get('capture') and value.get('emulation')


def topology(layout, nodes):
    if layout not in ('x99-left', 'alienware-left'):
        raise ValueError('Invalid layout')
    order = ['x99', 'mac', 'alienware'] if layout == 'x99-left' else ['alienware', 'mac', 'x99']
    return {host: dict({key: nodes[host][key] for key in ('capture_backend', 'emulation_backend') if key in nodes[host]}, peers=[dict(id=order[(i+offset) % 3], position=position,
                                 ips=nodes[order[(i+offset) % 3]]['ips'],
                                 fingerprint=nodes[order[(i+offset) % 3]]['fingerprint'])
                             for offset, position in ((-1, 'left'), (1, 'right'))])
            for i, host in enumerate(order)}


def prepare(layout):
    nodes = json.loads((BASE/'mesh.json').read_text())['nodes']
    profiles = topology(layout, nodes)
    for host in HOSTS:
        rpc(host, dict(action='configure', profile=profiles[host]))


def save_session(value):
    temp = BASE/('active.'+uuid.uuid4().hex+'.tmp')
    temp.write_text(json.dumps(value))
    temp.chmod(0o600)
    temp.replace(BASE/'active.json')


def main(request, legacy):
    if not enabled():
        return legacy(request)
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (BASE/'lifecycle.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return manage(request, legacy)


def manage(request, legacy):
    action = request.get('action', 'status')
    if action == 'stop':
        inputs = all_hosts('stop')
        result = legacy(request)
        save_session(dict(active=False))
        result['input'] = inputs
        failures = [h for h, v in inputs.items() if not v.get('ok')]
        if failures:
            result.update(ok=False, error='Não foi possível pausar a entrada em: '+', '.join(failures))
        return result
    if action == 'status':
        result = legacy(request)
        inputs = all_hosts('status')
        result['input'] = inputs
        try:
            active = json.loads((BASE/'active.json').read_text()).get('active', False)
        except (OSError, ValueError):
            active = False
        result['inputMode'] = 'mesh' if active else 'deskflow'
        if active:
            result['connected'] = [h for h in result.get('connected', [])
                                   if ready(inputs.get(h, {})) and ready(inputs.get('mac', {}))]
            pending = [h for h, v in inputs.items() if not ready(v)]
            result['detail'] = ('Entrada indisponível em: '+', '.join(pending) if pending
                                else 'Teclados e mouses dos três · Deskflow conectado')
        return result
    if action != 'start':
        raise ValueError('Invalid action')
    layout = request.get('layout', 'x99-left')
    try:
        active = json.loads((BASE/'active.json').read_text()).get('active', False)
    except (OSError, ValueError):
        active = False
    if active:
        status = manage(dict(action='status'), legacy)
        if status.get('running') and all(ready(v) for v in status['input'].values()):
            return dict(status, detail='Mesa contínua já está ativa')
        all_hosts('stop')
    prepare(layout)
    inputs = all_hosts('start')
    # Portal/backend creation is asynchronous. Do not take over a working Deskflow yet.
    deadline = time.monotonic()+3
    while not all(ready(v) for v in inputs.values()) and time.monotonic() < deadline:
        time.sleep(.3)
        inputs = all_hosts('status')
    pending = [h for h, v in inputs.items() if not ready(v)]
    if pending:
        if active:
            all_hosts('stop')
            legacy(dict(action='stop'))
            legacy(dict(request, inputMode='deskflow'))
            save_session(dict(active=False))
        return dict(ok=False, input=inputs, error='Autorize teclado e mouse no sistema: '+', '.join(pending))
    try:
        legacy(dict(action='stop'))
        result = legacy(dict(request, inputMode='mesh'))
        if not result.get('ok'):
            raise RuntimeError(result.get('error', 'Deskflow unavailable'))
        inputs = all_hosts('activate')
        if not all(v.get('ok') for v in inputs.values()):
            raise RuntimeError('Não foi possível ativar todos os dispositivos de entrada')
        save_session(dict(active=True, layout=layout))
        return dict(result, running=True, input=inputs, inputMode='mesh', detail='Todos os teclados e mouses conectados')
    except Exception:
        all_hosts('stop')
        legacy(dict(action='stop'))
        legacy(dict(request, inputMode='deskflow'))
        save_session(dict(active=False))
        raise
