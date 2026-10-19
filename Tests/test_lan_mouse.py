import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1]/'Integrations'/filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


w = module('lan_worker', 'lan-mouse-worker.py')
c = module('lan_control', 'lan-mouse-control.py')
a = module('macos_session_agent_test', 'macos-session-agent.py')
READY = dict(ok=True, running=True, capture=True, emulation=True)


class LanMouseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        for mod in (w, c):
            patcher = patch.object(mod, 'BASE', Path(directory.name))
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(w, 'session_agent')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_session_agent_refuses_to_stop_other_configuration(self):
        with patch.object(a, 'info', return_value='program = /other/engine'), patch.object(a.subprocess, 'run') as run:
            with self.assertRaises(RuntimeError):
                a.stop('local.insight-notch.lan-mouse', ['/app/engine', '--config', '/private/session'])
            run.assert_not_called()

    def test_native_backend_selection_cannot_silently_fall_back_to_dummy(self):
        with patch.object(w.sys, 'platform', 'darwin'):
            args = w.command()
            self.assertEqual(args[args.index('--capture-backend')+1], 'mac-os')
            self.assertEqual(args[args.index('--emulation-backend')+1], 'mac-os')
            self.assertNotIn('dummy', args)

    def test_ring_has_unique_neighbors_and_preserves_middle_layout(self):
        nodes = {h: dict(ips=['192.0.2.'+str(i+1)], fingerprint=(f'{i+1:02x}:'*32)[:-1]) for i, h in enumerate(c.HOSTS)}
        for layout, left, right in [('x99-left', 'x99', 'alienware'), ('alienware-left', 'alienware', 'x99')]:
            profiles = c.topology(layout, nodes)
            self.assertEqual([p['id'] for p in profiles['mac']['peers']], [left, right])
            for host, profile in profiles.items():
                w.validate_profile(profile)
                self.assertNotIn(host, [p['id'] for p in profile['peers']])
                for peer in profile['peers']:
                    self.assertIn(host, [p['id'] for p in profiles[peer['id']]['peers']])

    def test_rejects_broadcast_edges_and_shell_values(self):
        def peer(ident, pos):
            return dict(id=ident, position=pos, ips=['192.0.2.1'], fingerprint='ab:'*31+'ab')
        for peers in [[peer('one', 'left'), peer('two', 'left')],
                      [peer('one;bad', 'left'), peer('two', 'right')]]:
            with self.assertRaises(ValueError):
                w.validate_profile(dict(peers=peers))
        p = peer('one', 'left')
        for address in ('127.0.0.1', '0.0.0.0', '224.0.0.1', 'bad'):
            with self.assertRaises(ValueError):
                w.validate_profile(dict(peers=[dict(p, ips=[address]), peer('two', 'right')]))

    def test_configuration_is_private_and_contains_only_exact_authorizations(self):
        with tempfile.TemporaryDirectory() as root, patch.object(w, 'BASE', Path(root)):
            profile = dict(peers=[dict(id='one', position='left', ips=['192.0.2.1'], fingerprint='ab:'*31+'ab')])
            w.save(w.BASE/'profile.json', profile)
            w.write_config()
            self.assertEqual((w.BASE/'config.toml').stat().st_mode & 0o777, 0o600)
            self.assertEqual((w.BASE/'profile.json').stat().st_mode & 0o777, 0o600)
            import tomllib
            config = tomllib.loads((w.BASE/'config.toml').read_text())
            self.assertEqual(config['authorized_fingerprints'], {profile['peers'][0]['fingerprint']: 'one'})
            self.assertFalse(config['clients'][0]['activate_on_startup'])
            self.assertNotIn('enter_hook', config['clients'][0])
            self.assertNotIn('hostname', config['clients'][0])

    def test_supported_persistent_backends_survive_profile_and_configuration(self):
        nodes = {h: dict(ips=['192.0.2.'+str(i+1)], fingerprint=(f'{i+1:02x}:'*32)[:-1]) for i, h in enumerate(c.HOSTS)}
        nodes['x99'].update(capture_backend='layer-shell', emulation_backend='libei')
        profile = c.topology('alienware-left', nodes)['x99']
        w.validate_profile(profile)
        import tomllib
        config = tomllib.loads(w.config_text(profile))
        self.assertEqual(config['capture_backend'], 'layer-shell')
        self.assertEqual(config['emulation_backend'], 'libei')
        with self.assertRaises(ValueError):
            w.validate_profile(dict(profile, capture_backend='dummy'))

    def test_missing_permissions_never_interrupt_existing_deskflow(self):
        inputs = {h: dict(READY) for h in c.HOSTS}
        inputs['x99']['capture'] = False
        legacy = Mock()
        with patch.object(c, 'prepare'), patch.object(c, 'all_hosts', return_value=inputs), \
             patch.object(c.time, 'monotonic', side_effect=[0, 4]):
            result = c.manage(dict(action='start'), legacy)
        self.assertFalse(result['ok'])
        legacy.assert_not_called()

    def test_partial_activation_rolls_back_input_before_restoring_deskflow(self):
        actions = []
        def all_hosts(action):
            actions.append(('input', action))
            values = {h: dict(READY) for h in c.HOSTS}
            if action == 'activate':
                values['alienware'] = dict(ok=False, error='permission revoked')
            return values
        def legacy(request):
            actions.append(('deskflow', request['action'], request.get('inputMode')))
            return dict(ok=True)
        with patch.object(c, 'prepare'), patch.object(c, 'all_hosts', side_effect=all_hosts), patch.object(c, 'save_session'):
            with self.assertRaises(RuntimeError):
                c.manage(dict(action='start'), legacy)
        self.assertEqual(actions[-3:], [('input', 'stop'), ('deskflow', 'stop', None), ('deskflow', 'start', 'deskflow')])

    def test_recovery_failure_of_active_mesh_restores_deskflow(self):
        (c.BASE/'active.json').write_text(json.dumps(dict(active=True)))
        inputs = {h: dict(READY) for h in c.HOSTS}
        inputs['x99']['capture'] = False
        legacy = Mock(return_value=dict(ok=True, running=True, connected=[]))
        with patch.object(c, 'prepare'), patch.object(c, 'all_hosts', return_value=inputs), \
             patch.object(c.time, 'monotonic', side_effect=[0, 4]):
            result = c.manage(dict(action='start'), legacy)
        self.assertFalse(result['ok'])
        self.assertEqual(legacy.call_args.args[0], dict(action='start', inputMode='deskflow'))
        self.assertFalse(json.loads((c.BASE/'active.json').read_text())['active'])

    def test_permission_token_is_migrated_privately_and_not_replaced_after_rotation(self):
        original = w.BASE/'old-cache/lan-mouse/remote-desktop.token'
        original.parent.mkdir(parents=True)
        original.write_text('test-initial-permission')
        with patch.object(w.sys, 'platform', 'linux'), \
             patch.dict(w.os.environ, XDG_CACHE_HOME=str(w.BASE/'old-cache')):
            w.prepare_permission_cache()
            token = w.BASE/'cache/lan-mouse/remote-desktop.token'
            self.assertEqual(token.read_text(), original.read_text())
            self.assertEqual(token.stat().st_mode & 0o777, 0o600)
            token.write_text('test-rotated-permission')
            w.prepare_permission_cache()
            self.assertEqual(token.read_text(), 'test-rotated-permission')
            self.assertEqual(original.read_text(), 'test-initial-permission')

    def test_pipes_stopped_before_input_activation_and_same_toggle_pauses_both(self):
        actions = []
        def all_hosts(action):
            actions.append(('input', action))
            return {h: dict(READY) for h in c.HOSTS}
        def legacy(request):
            actions.append(('deskflow', request['action'], request.get('inputMode')))
            return dict(ok=True)
        with patch.object(c, 'prepare'), patch.object(c, 'all_hosts', side_effect=all_hosts), patch.object(c, 'save_session'):
            self.assertTrue(c.manage(dict(action='start'), legacy)['ok'])
            self.assertLess(actions.index(('deskflow', 'start', 'mesh')), actions.index(('input', 'activate')))
            self.assertTrue(c.manage(dict(action='stop'), legacy)['ok'])
            self.assertEqual(actions[-2:], [('input', 'stop'), ('deskflow', 'stop', None)])

    def test_stale_pid_is_not_killed(self):
        with patch.object(w, 'load', return_value=dict(pid=1234, identity='old')), \
             patch.object(w, 'process_identity', return_value='new'), patch.object(w, 'save'), \
             patch.object(w.os, 'kill') as kill:
            w.stop()
            kill.assert_not_called()

    def test_ipc_handles_fragmented_json_and_enforces_deadline(self):
        server, client = socket.socketpair()
        def serve():
            with server:
                self.assertEqual(json.loads(server.recv(4096)), 'Sync')
                server.sendall(b'{"CaptureStatus":')
                server.sendall(b'"Enabled"}\n{"EmulationStatus":"Enabled"}\n')
        thread = threading.Thread(target=serve)
        thread.start()
        with patch.object(w, 'desktop_env', return_value={'XDG_RUNTIME_DIR': '/run/test'}), \
             patch.object(w.socket, 'socket', return_value=client), patch.object(client.__class__, 'connect'):
            events = w.ipc(timeout=.3)
        thread.join()
        self.assertEqual(events, [{'CaptureStatus': 'Enabled'}, {'EmulationStatus': 'Enabled'}])


if __name__ == '__main__':
    unittest.main()
