"""Private, bounded recovery of an owned Windows UDP listener child."""
from contextlib import contextmanager
import hashlib
import copy
import ipaddress
import json
import os
import subprocess
import time
import tomllib
import uuid


@contextmanager
def lifecycle_lock(base):
    # OS locks release even when Task Scheduler terminates the supervisor.
    with (base/'receiver.lock').open('a+b') as handle:
        if handle.seek(0, 2) == 0:
            handle.write(b'0'); handle.flush()
        handle.seek(0)
        if os.name == 'nt':
            import msvcrt
            deadline = time.monotonic()+30
            while True:
                try:
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Receiver lifecycle lock unavailable')
                    time.sleep(.05)
        else:  # Local isolated fixtures; production entry points are Windows only.
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == 'nt':
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle, fcntl.LOCK_UN)


def protected(worker):
    return {name: hashlib.sha256((worker.BASE/name).read_bytes()).hexdigest()
            for name in ('profile.json', 'config.toml', 'identity.pem')}


def config_model(text):
    """Only known native serialization defaults are equivalent; retain every key."""
    value = tomllib.loads(text)
    # Native ports are Option<u16>; Python numeric equality alone also accepts
    # floats and bools. Reject them before comparing normalized models.
    if 'port' in value and (type(value['port']) is not int or not 0 <= value['port'] <= 65535):
        raise ValueError('Invalid listening port')
    if not isinstance(value.get('clients', []), list):
        raise ValueError('Invalid clients')
    for peer in value.get('clients', []):
        if not isinstance(peer, dict):
            raise ValueError('Invalid client')
        peer.setdefault('port', 4242)
        if type(peer['port']) is not int or not 0 <= peer['port'] <= 65535:
            raise ValueError('Invalid client port')
        peer.setdefault('activate_on_startup', False)
        if type(peer['activate_on_startup']) is not bool:
            raise ValueError('Invalid activation flag')
        if 'ips' in peer:
            if not isinstance(peer['ips'], list) or any(type(ip) is not str for ip in peer['ips']):
                raise ValueError('Invalid client addresses')
            peer['ips'] = sorted(str(ipaddress.ip_address(ip)) for ip in peer['ips'])
    value['clients'] = sorted(value.get('clients', []), key=lambda p: p.get('position', ''))
    return value


def models_equal(actual, expected):
    # Parsed TOML containers can use Python's int/float/bool coercing equality.
    # Canonical JSON retains their distinct scalar representations recursively.
    return json.dumps(actual, sort_keys=True) == json.dumps(expected, sort_keys=True)


def check_transaction(worker, control, state):
    current = worker.load(worker.BASE/'receiver-control.json')
    live = worker.load(worker.BASE/'session.json')
    if (current.get('generation') != control.get('generation') or
            any(live.get(k) != state.get(k) for k in ('generation', 'pid', 'identity'))):
        raise RuntimeError('cancelled')
    for name in ('profile.json', 'identity.pem'):
        if hashlib.sha256((worker.BASE/name).read_bytes()).hexdigest() != control['protected'][name]:
            raise RuntimeError('protected_state_changed')


def accept_config(worker, control, state, data, expected):
    check_transaction(worker, control, state)
    try:
        valid = models_equal(config_model(data.decode('utf-8')), expected)
    except (ValueError, TypeError, UnicodeError):
        valid = False
    if not valid or (worker.BASE/'config.toml').read_bytes() != data:
        raise RuntimeError('protected_state_changed')
    # Hash the exact bytes we validated, never a later unvalidated reread.
    control['protected']['config.toml'] = hashlib.sha256(data).hexdigest()
    control['configModel'] = expected
    worker.save(worker.BASE/'receiver-control.json', control)


def activate(worker, control, state, peers, active):
    """Caller holds lifecycle lock across native save_config and its Sync barrier."""
    try:
        for peer in peers:
            check_transaction(worker, control, state)
            if protected(worker) != control['protected']:
                raise RuntimeError('protected_state_changed')
            expected = copy.deepcopy(control['configModel'])
            target = next(p for p in expected['clients'] if p['position'] == peer['position'])
            if target['activate_on_startup'] == active:
                continue
            target['activate_on_startup'] = active
            worker.ipc({'Activate': [peer['handle'], active]}, .15)
            deadline = time.monotonic()+2
            while time.monotonic() < deadline:
                check_transaction(worker, control, state)
                # Native Activate calls synchronous save_config before handling
                # Sync. Its matching Enumerate proves that truncate/write ended.
                events = worker.ipc('Sync', .15)
                expected_flags = {p['position']: p['activate_on_startup'] for p in expected['clients']}
                enumerations = [e['Enumerate'] for e in events if isinstance(e, dict) and 'Enumerate' in e]
                if any(len(rows) == len(peers) and
                       {h for h, _, _ in rows} == {p['handle'] for p in peers} and
                       {c['pos'].lower(): s['active'] for _, c, s in rows} == expected_flags
                       for rows in enumerations):
                    accept_config(worker, control, state, (worker.BASE/'config.toml').read_bytes(), expected)
                    break
                time.sleep(.02)
            else:
                raise RuntimeError('activation_unconfirmed')
    except Exception as error:
        if worker.load(worker.BASE/'receiver-control.json').get('generation') == control.get('generation'):
            control['configFailure'] = ('protected_state_changed' if str(error) == 'protected_state_changed'
                                        else 'activation_unconfirmed')
            worker.save(worker.BASE/'receiver-control.json', control)
        raise


def prepare_replacement(worker, control):
    """A stopped child may have persisted active flags; never autoactivate a replacement."""
    if not any(p['activate_on_startup'] for p in control['configModel']['clients']):
        return
    state = worker.load(worker.BASE/'session.json')
    expected = copy.deepcopy(control['configModel'])
    for peer in expected['clients']:
        peer['activate_on_startup'] = False
    data = worker.config_text(worker.load(worker.BASE/'profile.json')).encode('utf-8')
    if not models_equal(config_model(data.decode('utf-8')), expected) or protected(worker) != control['protected']:
        raise RuntimeError('protected_state_changed')
    check_transaction(worker, control, state)
    (worker.BASE/'config.toml').write_bytes(data)
    accept_config(worker, control, state, data, expected)


def begin(worker, bootstrap=False):
    """Called under the lifecycle lock, after writing the inactive configuration."""
    value = dict(generation=uuid.uuid4().hex, active=False, bootstrap=bootstrap)
    if not bootstrap:
        profile = worker.validate_profile(worker.load(worker.BASE/'profile.json'))
        if (worker.BASE/'config.toml').read_text(encoding='utf-8') != worker.config_text(profile):
            raise ValueError('Receiver configuration differs from profile')
        value.update(protected=protected(worker), profileDigest=worker.profile_digest(),
                     configModel=config_model(worker.config_text(profile)))
    worker.save(worker.BASE/'receiver-control.json', value)
    worker.save(worker.BASE/'session.json', dict(generation=value['generation'],
                receiver=dict(state='starting', restarts=0)))
    return value['generation']


class LogTail:
    def __init__(self, path):
        self.path = path
        stat = path.stat()
        self.identity = (stat.st_dev, stat.st_ino)
        self.offset = stat.st_size
        self.pending = b''

    def failed(self):
        stat = self.path.stat()
        if (stat.st_dev, stat.st_ino) != self.identity or stat.st_size < self.offset:
            raise RuntimeError('log_changed')
        with self.path.open('rb') as stream:
            stream.seek(self.offset)
            chunk = stream.read(256*1024)
            self.offset += len(chunk)
        data = self.pending+chunk
        # Match the upstream receive-loop exit, not generic errors or peer liveness.
        failed = any(b'webrtc_util::conn::conn_udp_listener' in line and
                     b'ListenConfig pconn.recv_from error:' in line
                     for line in data.split(b'\n'))
        self.pending = data.rsplit(b'\n', 1)[-1][-4096:]
        return failed


def exact_peers(value, profile):
    peers = value.get('peers', [])
    expected = {(p['id'], p['position']) for p in profile['peers']}
    return (len(peers) == len(expected) and
            {(p.get('id'), p.get('position')) for p in peers} == expected and
            len({p.get('handle') for p in peers}) == len(peers))


class Supervisor:
    def __init__(self, worker, generation, bootstrap=False, delays=(1, 2, 4),
                 poll=.25, ready_timeout=15):
        self.w = worker
        self.generation = generation
        self.bootstrap = bootstrap
        self.delays = delays
        self.poll = poll
        self.ready_timeout = ready_timeout
        self.child = None
        self.restarts = 0
        self.state = {}

    def control(self):
        value = self.w.load(self.w.BASE/'receiver-control.json')
        return value if self.generation and value.get('generation') == self.generation else None

    def check(self):
        value = self.control()
        if value is None:
            raise RuntimeError('cancelled')
        if value.get('configFailure'):
            raise RuntimeError(value['configFailure'])
        if not self.bootstrap:
            try:
                unchanged = protected(self.w) == value.get('protected')
            except OSError:
                unchanged = False
            if not unchanged:
                raise RuntimeError('protected_state_changed')
        return value

    def publish(self, health, error=None):
        self.state['receiver'] = dict(state=health, restarts=self.restarts)
        if error:
            self.state['receiver']['error'] = error
        self.w.save(self.w.BASE/'session.json', self.state)

    def terminate(self):
        # Popen's retained process handle is authoritative, never a reused PID.
        if self.child is not None:
            if self.child.poll() is None:
                self.child.terminate()
                try:
                    self.child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.child.kill()
                    self.child.wait(timeout=3)
            self.child = None

    def spawn(self):
        with lifecycle_lock(self.w.BASE):
            control = self.check()
            if not self.bootstrap:
                prepare_replacement(self.w, control)
            with (self.w.BASE/'daemon.log').open('a', encoding='utf-8') as log:
                self.tail = LogTail(self.w.BASE/'daemon.log')
                try:
                    self.child = self.w.subprocess.Popen(
                        self.w.command(self.bootstrap), stdin=subprocess.DEVNULL,
                        stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW,
                        env=self.w.desktop_env(), cwd=self.w.binary().parent)
                except OSError:
                    raise RuntimeError('child_start_failed') from None
            identity = self.w.process_identity(self.child.pid)
            if not identity or self.child.poll() is not None:
                raise RuntimeError('child_start_failed')
            self.state = dict(pid=self.child.pid, identity=identity, bootstrap=self.bootstrap,
                              generation=self.generation,
                              profileDigest=control.get('profileDigest', self.w.profile_digest()))
            self.publish('starting')

    def initialize(self):
        deadline = time.monotonic()+self.ready_timeout
        activation_sent = False
        while time.monotonic() < deadline:
            with lifecycle_lock(self.w.BASE):
                self.check()
            # IPC/ownership queries may be slow. Keep them outside the lock so
            # deliberate stop can fence and reap while a query is in flight.
            value = self.w.status()
            if time.monotonic() >= deadline:
                raise RuntimeError('native_ready_timeout')
            with lifecycle_lock(self.w.BASE):
                control = self.check()
                if self.tail.failed():
                    return False
                if self.child.poll() is not None:
                    raise RuntimeError('child_exited')
                if value.get('running') and value.get('capture') and value.get('emulation'):
                    profile = self.w.validate_profile(self.w.load(self.w.BASE/'profile.json'))
                    if value.get('profileDigest') != control['profileDigest'] or not exact_peers(value, profile):
                        raise RuntimeError('native_profile_mismatch')
                    if control.get('active') and not all(p.get('active') for p in value['peers']):
                        if activation_sent:
                            raise RuntimeError('activation_unconfirmed')
                        activate(self.w, control, self.state, value['peers'], True)
                        activation_sent = True
                    else:
                        self.check()
                        if self.tail.failed():
                            return False
                        self.publish('ready')
                        return True
            time.sleep(self.poll)
        raise RuntimeError('native_ready_timeout')

    def backoff(self, delay):
        deadline = time.monotonic()+delay
        while time.monotonic() < deadline:
            with lifecycle_lock(self.w.BASE):
                self.check()
            time.sleep(min(self.poll, max(0, deadline-time.monotonic())))

    def run(self):
        try:
            while True:
                self.spawn()
                if self.bootstrap:
                    # Identity bootstrap keeps the old wait-only lifecycle.
                    return self.child.wait()
                initialized = self.initialize()
                while initialized:
                    with lifecycle_lock(self.w.BASE):
                        self.check()
                    if self.tail.failed():
                        break
                    if self.child.poll() is not None:
                        raise RuntimeError('child_exited')
                    time.sleep(self.poll)
                with lifecycle_lock(self.w.BASE):
                    self.check()
                    self.publish('recovering', 'listener_failed')
                    self.terminate()
                    if self.restarts >= len(self.delays):
                        raise RuntimeError('restart_limit')
                    delay = self.delays[self.restarts]
                    self.restarts += 1
                    self.publish('recovering', 'listener_failed')
                self.backoff(delay)
        except Exception as error:
            # Only bounded reason codes leave the private log, never paths/peers.
            reason = str(error)
            allowed = {'cancelled', 'protected_state_changed', 'log_changed', 'child_start_failed',
                       'child_exited', 'native_profile_mismatch', 'activation_unconfirmed',
                       'native_ready_timeout', 'restart_limit'}
            reason = reason if reason in allowed else 'supervisor_failed'
            with lifecycle_lock(self.w.BASE):
                if self.control() is not None:
                    self.publish('failed', reason)
                try:
                    self.terminate()
                except Exception:
                    # Keep the ownership evidence and report uncertainty if an
                    # OS refusal prevents reaping. Never create a second child.
                    reason = 'child_stop_failed'
                else:
                    self.state.pop('pid', None)
                    self.state.pop('identity', None)
                if self.control() is not None:
                    self.publish('failed', reason)
            return 1
        finally:
            if self.bootstrap and self.child is not None and self.child.poll() is not None:
                self.child = None
