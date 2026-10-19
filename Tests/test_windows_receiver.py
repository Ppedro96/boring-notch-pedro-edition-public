"""Real disposable children and log files; native IPC and Windows task API are fake."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1]/'Integrations'/filename)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


w = module('receiver_worker_test', 'lan-mouse-worker.py')
r = module('receiver_supervisor_test', 'windows-receiver.py')
c = module('receiver_control_test', 'lan-mouse-control.py')
FATAL = 'WARN webrtc_util::conn::conn_udp_listener: ListenConfig pconn.recv_from error: fixture error'
CHILD = '''
import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1]); pid = str(os.getpid())
(root/('ready-'+pid)).touch()
while True:
    trigger = root/('fatal-'+pid)
    if trigger.exists():
        print(sys.argv[2], flush=True)
        trigger.unlink()
    time.sleep(.01)
'''


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        self.children = []
        self.active = set()
        self.activations = []
        self.capture = True
        self.bad_edges = False
        self.ignore_activation = False
        self.rewrite_hook = None
        self.config_writes = []
        self.spawn_flags = []
        self.spawn_hook = None
        self.fail_spawn = False
        self.fake_identity = True
        self.supervisor = None
        self.thread = None
        self.patch(w, 'BASE', self.base)
        self.patch(w, 'windows', lambda: True)
        self.patch(w, 'session_agent')
        self.patch(w, 'binary', lambda: Path(sys.executable))
        self.patch(w, 'command', lambda bootstrap=False: [sys.executable, '-u', '-c', CHILD, str(self.base), FATAL])
        self.patch(w, 'desktop_env', lambda: None)
        self.patch(w, 'ipc', self.ipc)
        self.patch(w, 'process_identity', self.identity)
        self.patch(w, 'powershell', self.stop_task)
        real_popen = subprocess.Popen
        def spawn(*args, **kwargs):
            self.assertIn('creationflags', kwargs)
            kwargs.pop('creationflags')
            if self.fail_spawn:
                raise OSError('fixture start failure')
            child = real_popen(*args, **kwargs)
            self.children.append(child)
            self.active.clear()
            import tomllib
            self.active.update(10+i for i, peer in enumerate(tomllib.loads((self.base/'config.toml').read_text())['clients'])
                               if peer.get('activate_on_startup', False))
            self.spawn_flags.append(set(self.active))
            if self.spawn_hook:
                self.spawn_hook(child)
            return child
        self.patch(w.subprocess, 'Popen', spawn)
        self.patch(r.subprocess, 'CREATE_NO_WINDOW', 0, create=True)
        self.profile(1)
        (self.base/'identity.pem').write_bytes(b'fixture identity remains byte-identical')
        self.addCleanup(self.cleanup)

    def patch(self, obj, name, *args, **kwargs):
        value = patch.object(obj, name, *args, **kwargs)
        result = value.start()
        self.addCleanup(value.stop)
        return result

    def profile(self, count):
        self.peers = [dict(id='peer'+str(i), position=('left', 'right')[i],
                           ips=['192.0.2.'+str(i+1)], fingerprint=(f'{i+1:02x}:'*32)[:-1])
                      for i in range(count)]
        w.save(self.base/'profile.json', dict(peers=self.peers))
        w.write_config()

    def identity(self, pid):
        return 'fixture-'+str(pid) if self.fake_identity and any(p.pid == pid and p.poll() is None for p in self.children) else None

    def ipc(self, request='Sync', timeout=1):
        if not self.children or self.children[-1].poll() is not None:
            raise ConnectionRefusedError('no fixture child')
        child = self.children[-1]
        if not (self.base/('ready-'+str(child.pid))).exists():
            raise ConnectionRefusedError('fixture is starting')
        if isinstance(request, dict):
            handle, active = request['Activate']
            self.activations.append((child.pid, handle, active))
            if not self.ignore_activation:
                if active:
                    self.active.add(handle)
                else:
                    self.active.discard(handle)
            self.native_rewrite()
        peers = [[i+10, dict(hostname=None, fix_ips=p['ips'], pos='Top' if self.bad_edges else p['position'].title()),
                  dict(active=i+10 in self.active, alive=False)] for i, p in enumerate(self.peers)]
        return [{'CaptureStatus': 'Enabled' if self.capture else 'Disabled'},
                {'EmulationStatus': 'Enabled'}, {'Enumerate': peers}]

    def native_rewrite(self):
        # Native save_config serializes every client, drops default client ports
        # and false flags, and overwrites (truncates first) after each Activate.
        sections = w.config_text(w.load(self.base/'profile.json')).split('[[clients]]')
        for i in range(1, len(sections)):
            sections[i] = sections[i].replace('port = 4242\n', '')
            sections[i] = sections[i].replace('activate_on_startup = false\n',
                'activate_on_startup = true\n' if 9+i in self.active else '')
        content = ('[[clients]]'.join(sections)+'\n').replace(' = ', '  =  ')
        with (self.base/'config.toml').open('w') as output:
            if self.rewrite_hook:
                content = self.rewrite_hook(content)
            output.write(content)
        self.config_writes.append(content)

    def stop_task(self, script):
        # Emulate the actual stop ordering and verify fence was already committed.
        self.assertEqual(w.load(self.base/'receiver-control.json'), {})
        self.assertLess(script.index('Stop-ScheduledTask'), script.index('$owned=@'))
        self.assertIn('$live.CreationDate -eq $p.CreationDate', script)
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=3)
        return ''

    def cleanup(self):
        w.save(self.base/'receiver-control.json', {})
        if self.thread:
            self.thread.join(timeout=4)
            self.assertFalse(self.thread.is_alive(), 'supervisor fixture leaked')
        for child in self.children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=3)

    def until(self, condition, timeout=4):
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(.01)
        self.fail('fixture transition timed out: '+repr(w.load(self.base/'session.json')))

    def health(self):
        return w.load(self.base/'session.json').get('receiver', {}).get('state')

    def launch(self, active=True, delays=(.02, .04, .08), ready_timeout=.7):
        with r.lifecycle_lock(self.base):
            generation = r.begin(w)
        self.supervisor = r.Supervisor(w, generation, delays=delays, poll=.01, ready_timeout=ready_timeout)
        self.thread = threading.Thread(target=self.supervisor.run)
        self.thread.start()
        if not self.fail_spawn and self.fake_identity:
            self.until(lambda: self.health() in ('ready', 'failed'))
            if active and self.health() == 'ready':
                w.main(dict(action='activate'))

    def fatal(self):
        (self.base/('fatal-'+str(self.children[-1].pid))).touch()

    def worker_start(self, transition='publish', delay=0, known_pid=False):
        """Actual worker.start/status; only task execution and native IPC are fake."""
        calls = dict(starts=0, stops=0, observations=0)
        real_clock, real_sleep = time.monotonic, time.sleep
        def task(script):
            if 'Register-ScheduledTask' not in script:
                calls['stops'] += 1
                return self.stop_task(script)
            calls['starts'] += 1
            self.assertIn('pythonw.exe', script)
            self.assertIn('--generation', script)
            child = w.subprocess.Popen(w.command(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       creationflags=0)
            deadline = real_clock()+2
            while not (self.base/('ready-'+str(child.pid))).exists():
                if real_clock() >= deadline:
                    raise RuntimeError('fixture child not ready')
                real_sleep(.01)
            if known_pid:
                publish()
            return ''
        def publish():
            control = w.load(self.base/'receiver-control.json')
            child = self.children[-1]
            w.save(self.base/'session.json', dict(pid=child.pid, identity=self.identity(child.pid),
                   generation=control['generation'], profileDigest=control['profileDigest'],
                   receiver=dict(state='ready', restarts=0)))
        def observe(request='Sync', timeout=1):
            events = self.ipc(request, timeout)
            calls['observations'] += 1
            if calls['observations'] == delay+1:
                if transition == 'unknown_error':
                    raise RuntimeError('unexpected fixture IPC error')
                if transition == 'stop':
                    w.stop()
                elif transition != 'never_publish':
                    publish()
                    state = w.load(self.base/'session.json')
                    if transition == 'foreign_generation':
                        state['generation'] = 'unrelated-generation'
                    elif transition == 'foreign_identity':
                        state['identity'] = 'unrelated-creation'
                    elif transition == 'foreign_pid':
                        state['pid'] += 1
                    w.save(self.base/'session.json', state)
            return events
        self.start_calls = calls
        with patch.object(w, 'powershell', task), patch.object(w, 'ipc', observe):
            if transition == 'never_publish':
                with patch.object(w.time, 'monotonic', side_effect=range(100)), patch.object(w.time, 'sleep'):
                    return w.start()
            return w.start()

    def test_actual_worker_start_reobserves_its_initial_pid_publication(self):
        value = self.worker_start()
        self.assertTrue(value['running']); self.assertTrue(c.ready(value))
        self.assertEqual(self.start_calls, dict(starts=1, stops=1, observations=2))
        self.assertEqual(len(self.children), 1)
        self.assertEqual(self.activations, [])

    def test_actual_worker_start_waits_for_owned_publication_after_early_ipc(self):
        value = self.worker_start(delay=1)
        self.assertTrue(c.ready(value))
        self.assertEqual(self.start_calls, dict(starts=1, stops=1, observations=3))

    def test_ordinary_status_still_refuses_publication_without_start_context(self):
        ordinary_status = w.status
        with patch.object(w, 'status', side_effect=lambda **kwargs: ordinary_status()):
            with self.assertRaisesRegex(RuntimeError, 'session changed during status'):
                self.worker_start()
        self.assertEqual(self.start_calls, dict(starts=1, stops=1, observations=1))

    def test_actual_worker_start_does_not_retry_foreign_generation_or_identity(self):
        for transition in ('foreign_generation', 'foreign_identity'):
            with self.subTest(transition=transition):
                if self.children:
                    w.stop()
                with self.assertRaisesRegex(RuntimeError, 'cancelled or changed|ownership changed'):
                    self.worker_start(transition)
                self.assertEqual(self.start_calls, dict(starts=1, stops=1, observations=1))

    def test_actual_worker_start_does_not_accept_changed_published_pid(self):
        with self.assertRaisesRegex(RuntimeError, 'session changed during status'):
            self.worker_start('foreign_pid', known_pid=True)
        self.assertEqual(self.start_calls, dict(starts=1, stops=1, observations=1))

    def test_actual_worker_start_preserves_stop_fence_and_unknown_errors(self):
        with self.assertRaisesRegex(RuntimeError, 'cancelled or changed'):
            self.worker_start('stop')
        self.assertEqual(self.start_calls, dict(starts=1, stops=2, observations=1))
        self.assertTrue(all(p.poll() is not None for p in self.children))
        with self.assertRaisesRegex(RuntimeError, 'unexpected fixture IPC error'):
            self.worker_start('unknown_error')
        self.assertEqual(self.start_calls, dict(starts=1, stops=1, observations=1))

    def test_actual_worker_start_bounds_pending_publication_without_restarting(self):
        with self.assertRaisesRegex(RuntimeError, 'failed to start'):
            self.worker_start('never_publish')
        self.assertEqual(self.start_calls['starts'], 1)
        self.assertEqual(self.start_calls['stops'], 1)
        self.assertEqual(self.start_calls['observations'], 7)
        self.assertEqual(len(self.children), 1)

    def assert_failed(self, error):
        self.until(lambda: self.health() == 'failed')
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())
        self.assertEqual(w.load(self.base/'session.json')['receiver']['error'], error)
        self.assertTrue(all(p.poll() is not None for p in self.children))
        status = w.status()
        self.assertFalse(status['running'])
        self.assertFalse(c.ready(status))

    def test_stale_lines_and_normal_inactive_peers_do_not_restart(self):
        (self.base/'daemon.log').write_text(FATAL+'\n')
        self.launch(active=False)
        with (self.base/'daemon.log').open('a') as log:
            log.write('WARN ordinary peer inactive\nListenConfig pconn.recv_from error: unrelated source\n')
        time.sleep(.1)
        self.assertEqual(len(self.children), 1)
        self.assertEqual(self.health(), 'ready')
        self.assertEqual(self.activations, [])

    def test_recovers_exact_configured_peers_and_preserves_protected_bytes(self):
        for count in (1, 2):
            with self.subTest(count=count):
                if self.thread:
                    w.stop(); self.thread.join(timeout=2)
                self.profile(count)
                before = r.protected(w)
                self.launch()
                previous = self.children[-1]
                self.fatal()
                self.until(lambda: self.children[-1] is not previous and self.health() == 'ready')
                self.assertIsNotNone(previous.poll())
                current = self.children[-1]
                self.assertEqual([(h, on) for pid, h, on in self.activations if pid == current.pid],
                                 [(10+i, True) for i in range(count)])
                after = r.protected(w)
                self.assertEqual({k: v for k, v in after.items() if k != 'config.toml'},
                                 {k: v for k, v in before.items() if k != 'config.toml'})
                self.assertNotEqual(after['config.toml'], before['config.toml'])
                status = w.status()
                self.assertTrue(c.ready(status))
                self.assertEqual(status['profileDigest'], w.profile_digest())
                self.assertTrue(c.matches(status, dict(peers=self.peers)))

    def test_inactive_intent_survives_recovery(self):
        self.launch(active=False)
        self.fatal()
        self.until(lambda: len(self.children) == 2 and self.health() == 'ready')
        self.assertEqual(self.activations, [])

    def test_native_rewrites_initial_activation_deactivation_and_recovery_for_one_or_two_peers(self):
        for count in (1, 2):
            with self.subTest(count=count):
                if self.thread:
                    w.stop(); self.thread.join(timeout=2)
                self.profile(count)
                self.launch()
                current = self.children[-1]
                self.assertTrue(all(p['activate_on_startup'] for p in r.config_model(self.config_writes[-1])['clients']))
                if count == 2:
                    self.assertEqual([p['activate_on_startup'] for p in r.config_model(self.config_writes[-2])['clients']],
                                     [True, False])
                w.main(dict(action='deactivate'))
                self.assertFalse(any(p['activate_on_startup'] for p in r.config_model(self.config_writes[-1])['clients']))
                if count == 2:
                    self.assertEqual([p['activate_on_startup'] for p in r.config_model(self.config_writes[-2])['clients']],
                                     [False, True])
                time.sleep(.04)
                self.assertIsNone(current.poll()); self.assertEqual(self.health(), 'ready')
                w.main(dict(action='activate'))
                self.fatal()
                self.until(lambda: self.children[-1] is not current and self.health() == 'ready')
                self.assertFalse(any(self.spawn_flags), 'Replacement inherited active flags before readiness')
                self.assertTrue(all(p['activate_on_startup'] for p in r.config_model(self.config_writes[-1])['clients']))
                control = w.load(self.base/'receiver-control.json')
                self.assertEqual(control['protected'], r.protected(w))

    def test_owned_truncate_write_interval_does_not_fail_monitor(self):
        self.profile(2)
        self.launch(active=False)
        def paused_write(content):
            self.assertEqual((self.base/'config.toml').read_bytes(), b'')
            time.sleep(.05)  # Several monitor polls while native save_config owns the lock.
            return content
        self.rewrite_hook = paused_write
        w.main(dict(action='activate'))
        w.main(dict(action='deactivate'))
        self.assertEqual(self.health(), 'ready')
        self.assertIsNone(self.children[-1].poll())
        self.assertEqual(len(self.config_writes), 4)

    def test_unauthorized_mutations_during_owned_rewrite_are_never_adopted(self):
        mutations = {
            'peer_address': lambda s: s.replace('192.0.2.1', '192.0.2.99'),
            'peer_address_integer': lambda s: s.replace('"192.0.2.1"', '3221225985'),
            'grant': lambda s: s.replace('"peer0"', '"rogue"'),
            'capture': lambda s: 'capture_backend = "dummy"\n'+s,
            'emulation': lambda s: 'emulation_backend = "dummy"\n'+s,
            'listen_port': lambda s: s.replace('port  =  4242', 'port = 4243', 1),
            'peer_port': lambda s: s.replace('[[clients]]', '[[clients]]\nport = 4243', 1),
            'listen_port_float': lambda s: s.replace('port  =  4242', 'port = 4242.0', 1),
            'peer_port_float': lambda s: s.replace('[[clients]]', '[[clients]]\nport = 4242.0', 1),
            'listen_port_bool': lambda s: s.replace('port  =  4242', 'port = true', 1),
            'peer_port_bool': lambda s: s.replace('[[clients]]', '[[clients]]\nport = true', 1),
            'unknown_root': lambda s: 'unexpected = true\n'+s,
            'unknown_peer': lambda s: s.replace('[[clients]]', '[[clients]]\nunexpected = true', 1),
            'hook': lambda s: s.replace('[[clients]]', '[[clients]]\nenter_hook = "unexpected"', 1),
            'wrong_flag': lambda s: s.replace('activate_on_startup  =  true', 'activate_on_startup = false'),
        }
        for name, mutation in mutations.items():
            with self.subTest(mutation=name):
                self.rewrite_hook = None
                self.profile(1)
                self.launch(active=False)
                pinned = w.load(self.base/'receiver-control.json')['protected']['config.toml']
                self.rewrite_hook = mutation
                with self.assertRaisesRegex(RuntimeError, 'protected_state_changed'):
                    w.main(dict(action='activate'))
                self.assert_failed('protected_state_changed')
                self.assertEqual(w.load(self.base/'receiver-control.json')['protected']['config.toml'], pinned)

    def test_ports_require_exact_toml_u16_type_without_numeric_coercion(self):
        for value in ('4242.0', 'true', 'false', '"4242"', '-1', '65536'):
            for text in (f'port = {value}\n', f'[[clients]]\nport = {value}\n'):
                with self.subTest(text=text), self.assertRaises(ValueError):
                    r.config_model(text)
        for value in (0, 4242, 65535):
            model = r.config_model(f'port = {value}\n[[clients]]\nport = {value}\n')
            self.assertIs(type(model['port']), int)
            self.assertIs(type(model['clients'][0]['port']), int)
        omitted = r.config_model('[[clients]]\nposition = "left"\n')
        explicit = r.config_model('[[clients]]\nposition = "left"\nport = 4242\nactivate_on_startup = false\n')
        self.assertEqual(omitted, explicit)
        for value in ('1', '0', '1.0'):
            with self.subTest(active=value), self.assertRaises(ValueError):
                r.config_model(f'[[clients]]\nactivate_on_startup = {value}\n')
        for value in ('[3221225985]', '[true]', '"192.0.2.1"'):
            with self.subTest(ips=value), self.assertRaises(ValueError):
                r.config_model(f'[[clients]]\nips = {value}\n')

    def test_normalized_model_comparison_preserves_nested_scalar_types(self):
        for integer, wrong in ((4242, 4242.0), (1, True), (0, False)):
            with self.subTest(integer=integer, wrong=wrong):
                expected = dict(clients=[dict(port=integer)])
                candidate = dict(clients=[dict(port=wrong)])
                self.assertEqual(candidate, expected)  # The Python equality trap.
                self.assertFalse(r.models_equal(candidate, expected))
        self.assertTrue(r.models_equal(dict(port=4242, clients=[]), dict(clients=[], port=4242)))

    def test_certificate_or_profile_change_during_native_rewrite_is_refused(self):
        for filename in ('identity.pem', 'profile.json'):
            with self.subTest(filename=filename):
                self.rewrite_hook = None
                self.profile(1)
                self.launch(active=False)
                original = (self.base/filename).read_bytes()
                def mutate(content):
                    (self.base/filename).write_bytes(original+b' ')
                    return content
                self.rewrite_hook = mutate
                with self.assertRaisesRegex(RuntimeError, 'protected_state_changed'):
                    w.main(dict(action='activate'))
                self.assert_failed('protected_state_changed')
                (self.base/filename).write_bytes(original)

    def test_two_peer_transaction_does_not_authorize_unrequested_second_flag(self):
        self.profile(2)
        self.launch(active=False)
        def activate_other(content):
            first, second = content.rsplit('[[clients]]', 1)
            return first+'[[clients]]\nactivate_on_startup = true\n'+second
        self.rewrite_hook = activate_other
        with self.assertRaisesRegex(RuntimeError, 'protected_state_changed'):
            w.main(dict(action='activate'))
        self.assert_failed('protected_state_changed')
        self.assertEqual([(h, active) for _, h, active in self.activations], [(10, True)])

    def test_readiness_is_required_before_reactivation_and_truth_is_preserved(self):
        self.launch()
        self.capture = False
        self.fatal()
        self.until(lambda: len(self.children) == 2)
        self.until(lambda: (self.base/('ready-'+str(self.children[-1].pid))).exists())
        value = w.status()
        self.assertFalse(value['capture']); self.assertTrue(value['emulation'])
        self.assertFalse(c.ready(value)); self.assertEqual(value['receiver']['state'], 'starting')
        self.assertFalse(any(pid == self.children[-1].pid for pid, _, _ in self.activations))
        self.capture = True
        self.until(lambda: self.health() == 'ready')
        self.assertIn((self.children[-1].pid, 10, True), self.activations)

    def test_protected_identity_profile_and_config_changes_refuse_recovery(self):
        for filename in ('identity.pem', 'profile.json', 'config.toml'):
            with self.subTest(filename=filename):
                self.profile(1)
                self.launch()
                count = len(self.children)
                original = (self.base/filename).read_bytes()
                (self.base/filename).write_bytes(original+b' ')
                self.fatal()
                self.assert_failed('protected_state_changed')
                self.assertEqual(len(self.children), count)
                (self.base/filename).write_bytes(original)

    def test_bad_native_edges_refuse_activation(self):
        self.bad_edges = True
        self.launch(active=False)
        self.assert_failed('native_profile_mismatch')
        self.assertEqual(self.activations, [])

    def test_unconfirmed_activation_fails_closed(self):
        self.launch()
        self.ignore_activation = True
        self.fatal()
        self.assert_failed('activation_unconfirmed')

    def test_failed_initial_spawn_and_missing_creation_identity(self):
        self.fail_spawn = True
        self.launch()
        self.assert_failed('child_start_failed')
        self.fail_spawn = False
        self.fake_identity = False
        self.launch()
        self.assert_failed('child_start_failed')

    def test_failed_replacement_is_not_retried(self):
        self.launch()
        self.fail_spawn = True
        self.fatal()
        self.assert_failed('child_start_failed')
        self.assertEqual(len(self.children), 1)

    def test_restart_budget_is_lifetime_bounded(self):
        defaults = r.Supervisor(w, 'fixture')
        self.assertEqual(defaults.delays, (1, 2, 4))
        self.assertEqual(defaults.ready_timeout, 15)
        self.launch()
        for count in range(2, 5):
            self.fatal()
            self.until(lambda: len(self.children) == count and self.health() == 'ready')
        self.fatal()
        self.assert_failed('restart_limit')
        self.assertEqual(len(self.children), 4)
        self.assertEqual(w.status()['receiver']['restarts'], 3)

    def test_stop_refusal_preserves_failure_and_owned_process_evidence(self):
        self.launch()
        current = self.children[-1]
        with patch.object(current, 'terminate', side_effect=PermissionError('fixture refusal')):
            self.fatal()
            self.until(lambda: self.health() == 'failed')
            self.thread.join(timeout=2)
            self.assertFalse(self.thread.is_alive())
            value = w.status()
            self.assertEqual(value['receiver']['error'], 'child_stop_failed')
            self.assertTrue(value['running'])
            self.assertTrue(value['capture']); self.assertTrue(value['emulation'])
            self.assertFalse(c.ready(value))
            self.assertEqual(w.load(self.base/'session.json')['pid'], current.pid)
            self.assertEqual(len(self.children), 1)
        w.stop()

    def test_failed_task_stop_does_not_acknowledge_stopped_or_remove_evidence(self):
        self.launch()
        with patch.object(w, 'powershell', side_effect=RuntimeError('fixture stop refusal')):
            with self.assertRaisesRegex(RuntimeError, 'fixture stop refusal'):
                w.stop()
        self.assertEqual(w.load(self.base/'receiver-control.json'), {})
        self.assertNotEqual(self.health(), 'stopped')
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())
        self.assertTrue(all(p.poll() is not None for p in self.children))

    def test_fatal_split_across_reads_and_old_unterminated_line(self):
        path = self.base/'daemon.log'
        path.write_text(FATAL)
        tail = r.LogTail(path)
        with path.open('a') as log:
            log.write('\nordinary inactive peer\n')
        self.assertFalse(tail.failed())
        with path.open('a') as log:
            log.write(FATAL[:45])
        self.assertFalse(tail.failed())
        with path.open('a') as log:
            log.write(FATAL[45:]+'\n')
        self.assertTrue(tail.failed())

    def test_explicit_deactivation_remains_inactive_after_recovery(self):
        self.launch()
        w.main(dict(action='deactivate'))
        self.fatal()
        self.until(lambda: len(self.children) == 2 and self.health() == 'ready')
        self.assertFalse(any(pid == self.children[-1].pid for pid, _, _ in self.activations))

    def test_ready_timeout_and_unexpected_exit_do_not_loop(self):
        self.capture = False
        self.launch(active=False, ready_timeout=.1)
        self.assert_failed('native_ready_timeout')
        self.capture = True
        self.launch()
        self.children[-1].terminate()
        self.children[-1].wait(timeout=2)
        self.assert_failed('child_exited')
        self.assertEqual(len(self.children), 2)

    def test_stop_during_backoff_cancels_replacement(self):
        self.launch(delays=(.5, 1, 2))
        self.fatal()
        self.until(lambda: self.health() == 'recovering')
        self.assertTrue(w.stop()['ok'])
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())
        self.assertEqual(len(self.children), 1)
        self.assertEqual(self.health(), 'stopped')

    def test_deactivate_during_backoff_fences_reactivation(self):
        self.launch(delays=(.2, .4, .8))
        self.fatal()
        self.until(lambda: self.health() == 'recovering')
        w.main(dict(action='deactivate'))
        self.until(lambda: len(self.children) == 2 and self.health() == 'ready')
        self.assertFalse(any(pid == self.children[-1].pid for pid, _, _ in self.activations))

    def test_stop_during_slow_ready_query_does_not_wait_for_query_or_reactivate(self):
        self.launch()
        entered = threading.Event()
        release = threading.Event()
        original = w.status
        def slow_status():
            entered.set()
            if not release.wait(timeout=2):
                raise RuntimeError('fixture query timed out')
            return original()
        with patch.object(w, 'status', slow_status):
            self.fatal()
            self.assertTrue(entered.wait(timeout=2))
            self.assertTrue(w.stop()['ok'])
            self.assertTrue(all(p.poll() is not None for p in self.children))
            release.set()
            self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())
        self.assertEqual(self.health(), 'stopped')
        self.assertFalse(any(pid == self.children[-1].pid for pid, _, _ in self.activations))

    def test_protected_change_during_backoff_prevents_new_child(self):
        self.launch(delays=(.2, .4, .8))
        self.fatal()
        self.until(lambda: self.health() == 'recovering')
        (self.base/'identity.pem').unlink()
        self.assert_failed('protected_state_changed')
        self.assertEqual(len(self.children), 1)

    def test_stop_racing_spawn_waits_for_lock_then_fences_and_reaps_child(self):
        self.launch()
        spawned = threading.Event()
        release = threading.Event()
        def blocked_spawn(child):
            spawned.set()
            if not release.wait(timeout=2):
                raise RuntimeError('fixture barrier timed out')
        self.spawn_hook = blocked_spawn
        self.fatal()
        self.assertTrue(spawned.wait(timeout=2))
        stopped = []
        stopper = threading.Thread(target=lambda: stopped.append(w.stop()))
        stopper.start()
        time.sleep(.03)
        self.assertTrue(stopper.is_alive())
        release.set()
        stopper.join(timeout=3)
        self.thread.join(timeout=3)
        self.assertFalse(stopper.is_alive()); self.assertFalse(self.thread.is_alive())
        self.assertEqual(stopped, [dict(ok=True, running=False)])
        self.assertTrue(all(p.poll() is not None for p in self.children))
        self.assertEqual(len(self.children), 2)
        self.assertEqual(self.health(), 'stopped')

    def test_stopped_generation_cannot_start_late(self):
        with r.lifecycle_lock(self.base):
            old = r.begin(w)
        w.stop()
        self.assertEqual(r.Supervisor(w, old).run(), 1)
        self.assertEqual(self.children, [])
        self.assertEqual(self.health(), 'stopped')

    def test_truncated_log_fails_closed(self):
        self.launch()
        with (self.base/'daemon.log').open('a') as log:
            log.write('ordinary new line\n')
        self.until(lambda: self.supervisor.tail.offset > 0)
        (self.base/'daemon.log').write_text('')
        self.assert_failed('log_changed')

    def test_controller_excludes_bad_receiver_without_erasing_native_or_activity_evidence(self):
        value = dict(ok=True, running=True, capture=True, emulation=True,
                     peers=[dict(id='peer0', position='left', active=True, alive=True)])
        for state in ('unknown', 'starting', 'recovering', 'failed', 'stopped'):
            value['receiver'] = dict(state=state)
            self.assertFalse(c.ready(value))
            self.assertTrue(value['capture']); self.assertTrue(value['emulation'])
            self.assertTrue(c.activated(value))
        value.pop('receiver')  # Mac/Linux retain their existing readiness contract.
        self.assertTrue(c.ready(value))


if __name__ == '__main__':
    unittest.main()
