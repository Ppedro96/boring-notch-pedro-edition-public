#!/usr/bin/env python3
"""Coordinate bidirectional input with the existing Mesa lifecycle, with rollback."""
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

LOCAL_HOST = 'mac' if sys.platform == 'darwin' else 'x99'
BASE = Path.home()/('.local/share/pedro-notch/lan-mouse' if LOCAL_HOST == 'mac' else '.local/share/insight-notch/lan-mouse')
HOSTS = ('mac', 'x99', 'alienware')
REMOTE_WORKER = '.local/share/insight-notch/lan-mouse-worker.py'


def enabled():
    try:
        return json.loads((BASE/'mesh.json').read_text()).get('enabled') is True
    except (OSError, ValueError):
        return False


def rpc(host, request):
    if host not in HOSTS:
        raise ValueError('invalid input host')
    if host == LOCAL_HOST:
        worker = Path(__file__).with_name('lan-mouse-worker.py') if LOCAL_HOST == 'mac' else Path.home()/REMOTE_WORKER
        args = [sys.executable, str(worker)]
    else:
        code = base64.b64encode(('import runpy;from pathlib import Path;runpy.run_path(str(Path.home()/'
                                 +repr('.local/share/pedro-notch/lan-mouse-worker.py' if host == 'mac' else REMOTE_WORKER)+"),run_name='__main__')").encode()).decode()
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


def all_hosts(action, hosts=HOSTS):
    def run(host):
        try:
            return host, rpc(host, dict(action=action))
        except Exception as error:
            return host, dict(ok=False, running=False, error=str(error))
    with ThreadPoolExecutor(max_workers=3) as pool:
        return dict(pool.map(run, hosts))


def ready(value):
    return (value.get('ok') and value.get('running') and value.get('capture') and value.get('emulation')
            and value.get('receiver', {}).get('state', 'ready') == 'ready')


def topology(layout, nodes, hosts=HOSTS):
    if layout not in ('x99-left', 'alienware-left'):
        raise ValueError('Invalid layout')
    if len(hosts) not in (2, 3) or len(set(hosts)) != len(hosts) or not set(hosts) <= set(HOSTS):
        raise ValueError('Two or three distinct hosts are required')
    order = ['x99', 'mac', 'alienware'] if layout == 'x99-left' else ['alienware', 'mac', 'x99']
    order = [h for h in order if h in hosts]
    return {host: dict({key: nodes[host][key] for key in ('capture_backend', 'emulation_backend') if key in nodes[host]},
                      peers=[dict(id=order[j], position=position, ips=nodes[order[j]]['ips'],
                                  fingerprint=nodes[order[j]]['fingerprint'])
                             for j, position in ((i-1, 'left'), (i+1, 'right')) if 0 <= j < len(order)])
            for i, host in enumerate(order)}


def digest(profile):
    return hashlib.sha256(json.dumps(profile, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def matches(value, profile):
    # Require launch evidence AND current IPC edges; a profile file or marker
    # alone cannot confirm a legacy daemon or an externally changed edge.
    expected = {(p['id'], p['position']) for p in profile['peers']}
    actual = [(p.get('id'), p.get('position')) for p in value.get('peers', [])]
    return (value.get('profileDigest') == digest(profile) and len(actual) == len(expected)
            and set(actual) == expected)


def activated(value):
    return bool(value.get('peers')) and all(p.get('active') for p in value['peers'])


def prepare(profiles, hosts):
    results = {}
    for host in hosts:
        try:
            rpc(host, dict(action='stop'))
            results[host] = rpc(host, dict(action='configure', profile=profiles[host]))
        except Exception as error:
            results[host] = dict(ok=False, error=str(error))
    return results


def save_session(value):
    BASE.mkdir(mode=0o700,parents=True,exist_ok=True)
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


def session():
    try:return json.loads((BASE/'active.json').read_text())
    except (OSError,ValueError):return dict(active=False)


def native_status():
    state = session()
    inputs = all_hosts('status')
    participants = state.get('participants', [])
    layout = state.get('layout', 'alienware-left')
    nodes = json.loads((BASE/'mesh.json').read_text())['nodes']
    profiles = topology(layout, nodes, participants) if len(participants) >= 2 else {}
    confirmed = [h for h in participants if h in profiles and matches(inputs[h], profiles[h])]
    pending = [h for h in HOSTS if h not in confirmed]
    inputs = {h: dict(v, layoutPending=True) if h in pending else v for h, v in inputs.items()}
    available = [h for h in HOSTS if h in confirmed and ready(inputs[h]) and activated(inputs[h])]
    connected = set()
    usable = False
    for host in available:
        for peer in inputs[host].get('peers', []):
            other = peer.get('id')
            if other in available:
                usable = True
                if peer.get('alive'):
                    connected.update((host, other))
    active = bool(state.get('active'))
    missing = [h for h in HOSTS if h not in available]
    return dict(ok=True, running=active and usable, active=active,
                inputMode='mesh', layout=layout, input=inputs, ready=available,
                connected=sorted(connected), partial=bool(missing), pending=pending,
                unconfirmed=state.get('unconfirmed', []),
                detail=('Layout pendente em: '+', '.join(pending) if pending else
                        'Entrada indisponível em: '+', '.join(missing) if missing else
                        'Teclados e mouses prontos'))


def optional_legacy(request, legacy):
    try:return legacy(request)
    except Exception as error:return dict(ok=False,error=str(error))


def manage(request, legacy):
    action = request.get('action','status')
    state = session()
    layout = state.get('layout','alienware-left')
    if action == 'status':
        return native_status()
    if action == 'home':
        # Mesh input is bidirectional: Home identifies the physical caller and
        # never switches authority to the Mac or tears down native sessions.
        return dict(ok=True,inputMode='mesh',home=request.get('_continuityPeer',LOCAL_HOST),layout=layout)
    if action == 'mode':
        return dict(ok=True,inputMode='mesh',layout=layout)
    if action == 'layout':
        if 'layout' not in request:return dict(ok=True,layout=layout,inputMode='mesh')
        target=request['layout']
        if target not in ('x99-left','alienware-left'):raise ValueError('Invalid layout')
        if state.get('active'):
            return manage(dict(action='start', layout=target), legacy)
        save_session(dict(active=False, layout=target, participants=[], pending=list(HOSTS)))
        return dict(ok=True, layout=target, inputMode='mesh', active=False, running=False)
    if action == 'stop':
        inputs = all_hosts('stop')
        compatibility = optional_legacy(dict(action='stop'),legacy)
        failures = [h for h,v in inputs.items() if not v.get('ok')]
        save_session(dict(state,active=bool(failures),layout=layout,unconfirmed=failures))
        return dict(ok=not failures,running=False,active=bool(failures),inputMode='mesh',layout=layout,
                    input=inputs,ready=[],connected=[],partial=bool(failures),
                    unconfirmed=failures,
                    error=('Não foi possível confirmar pausa em: '+', '.join(failures)) if failures else '',
                    clipboard=compatibility)
    if action != 'start':raise ValueError('Invalid action')
    layout = request.get('layout', layout)
    if layout not in ('x99-left', 'alienware-left'):
        raise ValueError('Invalid layout')
    nodes = json.loads((BASE/'mesh.json').read_text())['nodes']
    inputs = all_hosts('status')
    candidates = [h for h in HOSTS if inputs[h].get('ok')]
    # RPC failure is not evidence that a previously active native session ended.
    # Retain that possibility until stop is acknowledged, including a lost
    # activation reply. This also keeps later explicit layouts reconcilable.
    unconfirmed = set(state.get('unconfirmed', []))
    if state.get('active'):
        unconfirmed.update(state.get('participants') or HOSTS)
    unconfirmed.update(h for h, v in inputs.items() if v.get('running') and activated(v))
    compatibility = None
    errors = {}
    # Each failed pass removes at least one participant. A later explicit start
    # rediscovers returned peers; polling only reports the current graph.
    for _ in range(len(HOSTS)):
        if len(candidates) < 2:
            break
        profiles = topology(layout, nodes, candidates)
        changed = [h for h in candidates if not (ready(inputs[h]) and matches(inputs[h], profiles[h]))]
        # Invalidate confirmation before touching profiles, including failures
        # between stop/configure/start. Stale daemons cannot remain participants.
        retained = [h for h in candidates if h not in changed and activated(inputs[h])]
        save_session(dict(active=bool(unconfirmed), layout=layout,
                          participants=retained, pending=[h for h in HOSTS if h not in retained],
                          unconfirmed=sorted(unconfirmed)))
        prepared = prepare(profiles, changed)
        configured = [h for h in changed if prepared[h].get('ok')]
        unconfirmed.difference_update(configured)  # configure follows acknowledged stop
        started = all_hosts('start', configured) if configured else {}
        deadline = time.monotonic()+3
        while any(not ready(started.get(h, {})) for h in configured) and time.monotonic() < deadline:
            time.sleep(.3)
            started = all_hosts('status', configured)
        inputs.update(started)
        failed = [h for h in changed if h not in configured or not ready(inputs[h]) or not matches(inputs[h], profiles[h])]
        if failed:
            errors.update({h: prepared.get(h) if h not in configured else inputs[h] for h in failed})
            # A failed configure is never started or activated; stop newly started
            # but unusable sessions before deriving the smaller adjacent pair.
            stopped = all_hosts('stop', [h for h in failed if h in configured])
            unconfirmed.difference_update(h for h, v in stopped.items() if v.get('ok') and not v.get('running'))
            candidates = [h for h in candidates if h not in failed]
            continue
        if not state.get('active') and compatibility is None:
            optional_legacy(dict(action='stop'), legacy)
            compatibility = optional_legacy(dict(action='start', inputMode='mesh', layout=layout), legacy)
        needs_activation = [h for h in candidates if not activated(inputs[h])]
        unconfirmed.update(needs_activation)
        results = all_hosts('activate', needs_activation) if needs_activation else {}
        inputs.update(results)
        failed = [h for h in candidates if not (ready(inputs[h]) and matches(inputs[h], profiles[h]) and activated(inputs[h]))]
        if failed:
            errors.update({h: inputs[h] for h in failed})
            stopped = all_hosts('stop', failed)
            unconfirmed.difference_update(h for h, v in stopped.items() if v.get('ok') and not v.get('running'))
            candidates = [h for h in candidates if h not in failed]
            continue
        pending = [h for h in HOSTS if h not in candidates]
        unconfirmed.difference_update(candidates)
        save_session(dict(active=True, layout=layout, participants=candidates, pending=pending,
                          unconfirmed=sorted(unconfirmed)))
        result = dict(ok=True, running=True, active=True, input=inputs, inputMode='mesh', layout=layout,
                      ready=candidates, connected=[], partial=bool(pending), pending=pending,
                      unconfirmed=sorted(unconfirmed),
                      detail='Teclados e mouses disponíveis ativados')
        if compatibility is not None:
            result['clipboard'] = compatibility
        return result
    if compatibility is not None:
        stopped = all_hosts('stop', candidates)
        unconfirmed.difference_update(h for h, v in stopped.items() if v.get('ok') and not v.get('running'))
        if not unconfirmed:
            optional_legacy(dict(action='stop'), legacy)
            optional_legacy(dict(action='start', inputMode='deskflow'), legacy)
    active = bool(unconfirmed)
    save_session(dict(active=active, layout=layout, participants=state.get('participants', []) if active else [],
                      pending=list(HOSTS), unconfirmed=sorted(unconfirmed)))
    return dict(ok=False, running=False, active=active, inputMode='mesh', layout=layout,
                input=inputs, ready=[], connected=[], partial=True, pending=list(HOSTS), failures=errors,
                unconfirmed=sorted(unconfirmed),
                error='Menos de duas máquinas com o layout e os dispositivos confirmados')
