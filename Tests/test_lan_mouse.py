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
        self.nodes = {h: dict(ips=['192.0.2.'+str(i+1)], fingerprint=(f'{i+1:02x}:'*32)[:-1]) for i, h in enumerate(c.HOSTS)}
        (c.BASE/'mesh.json').write_text(json.dumps(dict(enabled=True, nodes=self.nodes)))
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

    def test_linear_exact_edges_and_absent_outer_capture_regions(self):
        import tomllib
        for layout, left, right in [('x99-left', 'x99', 'alienware'), ('alienware-left', 'alienware', 'x99')]:
            profiles = c.topology(layout, self.nodes)
            self.assertEqual({h: [(p['id'], p['position']) for p in v['peers']] for h, v in profiles.items()},
                             {left: [('mac', 'right')], 'mac': [(left, 'left'), (right, 'right')], right: [('mac', 'left')]})
            for host, profile in profiles.items():
                w.validate_profile(profile)
                config = tomllib.loads(w.config_text(profile))
                self.assertEqual([p['position'] for p in config['clients']], [p['position'] for p in profile['peers']])
                self.assertEqual(len(config['authorized_fingerprints']), len(profile['peers']))
            pair = c.topology(layout, self.nodes, ['x99', 'alienware'])
            self.assertEqual([(p['id'], p['position']) for p in pair[left]['peers']], [(right, 'right')])
            self.assertEqual([(p['id'], p['position']) for p in pair[right]['peers']], [(left, 'left')])

    def test_profiles_require_one_or_two_unique_valid_neighbors(self):
        good = c.topology('alienware-left', self.nodes)['mac']['peers']
        for peers in ([], good+[good[0]], [good[0], good[0]],
                      [dict(good[0], position='top')],
                      [dict(good[0], fingerprint='bad')],
                      [dict(good[0], ips=[])],
                      [good[0], dict(good[1], position='left')],
                      [good[0], dict(good[1], fingerprint=good[0]['fingerprint'])],
                      [good[0], dict(good[1], ips=good[0]['ips'])]):
            with self.subTest(peers=peers), self.assertRaises(ValueError):
                w.validate_profile(dict(peers=peers))
        for hosts in ([], ['mac'], ['mac','mac'], ['mac','unknown']):
            with self.assertRaises(ValueError):
                c.topology('alienware-left', self.nodes, hosts)

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

    def fake_workers(self, layout='alienware-left', participants=(), legacy_ring=False):
        profiles = c.topology(layout, self.nodes)
        if legacy_ring:
            order = ['alienware', 'mac', 'x99'] if layout == 'alienware-left' else ['x99', 'mac', 'alienware']
            for i, host in enumerate(order):
                profiles[host]['peers'] = [dict(id=order[j % 3], position=pos, **self.nodes[order[j % 3]])
                                          for j, pos in ((i-1, 'left'), (i+1, 'right'))]
        elif len(participants) >= 2:
            profiles.update(c.topology(layout, self.nodes, participants))
        self.calls = []
        self.offline = set()
        self.config_fail = set()
        self.permission_fail = set()
        self.activate_fail = set()
        self.live = {}
        self.profiles = profiles
        def status(host):
            profile = self.live.get(host)
            return dict(ok=True, running=profile is not None,
                        capture=profile is not None and host not in self.permission_fail,
                        emulation=profile is not None,
                        profileDigest=c.digest(profile) if profile else None,
                        peers=[dict(id=p['id'], position=p['position'], alive=False, active=host in active)
                               for p in profile['peers']] if profile else [])
        active = set(participants)
        self.live.update({h: json.loads(json.dumps(profiles[h])) for h in participants})
        c.save_session(dict(active=bool(participants), layout=layout, participants=list(participants), pending=[h for h in c.HOSTS if h not in participants]))
        def rpc(host, request):
            action = request['action']; self.calls.append((host, action))
            if host in self.offline:
                raise RuntimeError('offline')
            if action == 'stop':
                self.live.pop(host, None); active.discard(host)
            elif action == 'configure':
                if host in self.config_fail:
                    raise RuntimeError('configure failed')
                w.validate_profile(request['profile'])
                self.profiles[host] = request['profile']
            elif action == 'start':
                if host not in self.live:
                    self.live[host] = json.loads(json.dumps(self.profiles[host]))
            elif action == 'activate':
                if host in self.activate_fail:
                    raise RuntimeError('activate failed')
                active.add(host)
            return status(host)
        patcher = patch.object(c, 'rpc', side_effect=rpc)
        patcher.start(); self.addCleanup(patcher.stop)
        return Mock(return_value=dict(ok=True))

    def assert_live_graph(self, layout, participants):
        expected = c.topology(layout, self.nodes, participants)
        for host in participants:
            self.assertEqual(self.live[host], expected[host])
        self.assertEqual(set(c.session()['participants']), set(participants))

    def test_legacy_ring_is_pending_until_explicit_start_migrates_exact_edges(self):
        legacy = self.fake_workers(participants=c.HOSTS, legacy_ring=True)
        status = c.manage(dict(action='status'), legacy)
        self.assertFalse(status['running'])
        self.assertEqual(status['pending'], ['x99', 'alienware'])
        self.assertEqual(set(a for _, a in self.calls), {'status'})
        self.calls.clear()
        result = c.manage(dict(action='start'), legacy)
        self.assertTrue(result['ok']); self.assertEqual(result['pending'], [])
        self.assert_live_graph('alienware-left', c.HOSTS)
        self.assertFalse(any(h == 'mac' and a != 'status' for h, a in self.calls))
        legacy.assert_not_called()

    def test_legacy_session_without_launch_evidence_cannot_be_confirmed(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        real = c.rpc.side_effect
        def no_digest(host, request):
            result = real(host, request)
            if request['action'] == 'status': result.pop('profileDigest')
            return result
        c.rpc.side_effect = no_digest
        status = c.manage(dict(action='status'), legacy)
        self.assertEqual(status['ready'], [])
        self.assertEqual(status['pending'], list(c.HOSTS))
        self.assertFalse(status['running'])

    def test_partial_status_does_not_claim_disconnected_endpoints_running_or_mutate(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        self.offline.add('mac')
        status = c.manage(dict(action='status'), legacy)
        self.assertFalse(status['running']); self.assertTrue(status['partial'])
        self.assertEqual(set(a for _, a in self.calls), {'status'})
        legacy.assert_not_called()

    def test_receiver_failure_excludes_ready_but_keeps_actual_backends_and_activity(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        original = c.rpc.side_effect
        def unhealthy(host, request):
            result = original(host, request)
            if host == 'alienware':
                result['receiver'] = dict(state='recovering', restarts=1, error='listener_failed')
            return result
        c.rpc.side_effect = unhealthy
        before = c.session()
        result = c.manage(dict(action='status'), legacy)
        self.assertNotIn('alienware', result['ready'])
        self.assertTrue(result['input']['alienware']['capture'])
        self.assertTrue(result['input']['alienware']['emulation'])
        self.assertTrue(result['active'])
        self.assertEqual(c.session(), before)
        self.assertEqual(set(a for _, a in self.calls), {'status'})
        legacy.assert_not_called()

    def test_failed_active_start_keeps_input_evidence_and_next_layout_reconciles(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        before = json.loads(json.dumps(self.live))
        self.offline.update(['x99', 'alienware'])
        result = c.manage(dict(action='start'), legacy)
        self.assertFalse(result['ok']); self.assertFalse(result['running'])
        self.assertTrue(result['active'])
        self.assertEqual(set(result['unconfirmed']), set(c.HOSTS))
        self.assertEqual(c.session()['participants'], list(c.HOSTS))
        self.assertEqual(self.live, before)
        self.assertEqual(set(a for _, a in self.calls), {'status'})
        self.calls.clear()
        saved = c.session()
        status = c.manage(dict(action='status'), legacy)
        self.assertTrue(status['active']); self.assertFalse(status['running'])
        self.assertEqual(c.session(), saved)
        self.assertEqual(set(a for _, a in self.calls), {'status'})
        # An explicit layout must attempt reconciliation even if RPCs still fail.
        self.calls.clear()
        failed_layout = c.manage(dict(action='layout', layout='x99-left'), legacy)
        self.assertFalse(failed_layout['ok']); self.assertTrue(failed_layout['active'])
        self.assertEqual(set(h for h, _ in self.calls), set(c.HOSTS))
        self.assertEqual(self.live, before)
        self.offline.clear(); self.calls.clear()
        result = c.manage(dict(action='layout', layout='x99-left'), legacy)
        self.assertTrue(result['ok']); self.assert_live_graph('x99-left', c.HOSTS)
        self.assertEqual({h for h, a in self.calls if a == 'configure'}, set(c.HOSTS))
        self.assertEqual(c.session()['unconfirmed'], [])
        legacy.assert_not_called()

    def test_linux_can_start_two_peers_despite_unavailable_mac_clipboard(self):
        legacy = self.fake_workers(); self.offline.add('mac')
        legacy.side_effect = RuntimeError('Mac asleep')
        result = c.manage(dict(action='start'), legacy)
        self.assertTrue(result['running']); self.assertTrue(result['partial'])
        self.assertFalse(result['clipboard']['ok'])
        self.assert_live_graph('alienware-left', ['x99', 'alienware'])

    def test_partial_layout_change_does_not_require_sleeping_mac(self):
        legacy = self.fake_workers(participants=['x99', 'alienware']); self.offline.add('mac')
        result = c.manage(dict(action='layout', layout='x99-left'), legacy)
        self.assertTrue(result['ok']); self.assertTrue(result['partial'])
        self.assert_live_graph('x99-left', ['x99', 'alienware'])

    def test_returning_center_reconfigures_both_endpoints_only_on_explicit_start(self):
        legacy = self.fake_workers(participants=['x99', 'alienware']); self.offline.add('mac')
        c.manage(dict(action='start'), legacy)
        self.offline.clear(); self.calls.clear()
        before = c.session()
        status = c.manage(dict(action='status'), legacy)
        self.assertEqual(c.session(), before); self.assertEqual(status['pending'], ['mac'])
        self.assertEqual(set(a for _, a in self.calls), {'status'})
        self.calls.clear()
        result = c.manage(dict(action='start'), legacy)
        self.assertTrue(result['running']); self.assertFalse(result['partial'])
        self.assert_live_graph('alienware-left', c.HOSTS)
        self.assertEqual({h for h, a in self.calls if a == 'configure'}, set(c.HOSTS))
        self.calls.clear()
        c.manage(dict(action='start'), legacy)
        self.assertEqual(set(a for _, a in self.calls), {'status'})

    def test_returning_endpoint_preserves_unchanged_opposite_endpoint(self):
        legacy = self.fake_workers(participants=['mac', 'x99'])
        result = c.manage(dict(action='start'), legacy)
        self.assertTrue(result['ok']); self.assert_live_graph('alienware-left', c.HOSTS)
        self.assertFalse(any(h == 'x99' and a != 'status' for h, a in self.calls))
        self.assertEqual({h for h, a in self.calls if a == 'configure'}, {'mac', 'alienware'})

    def test_failed_configure_cannot_start_activate_or_report_old_profile_ready(self):
        legacy = self.fake_workers(participants=c.HOSTS, legacy_ring=True)
        self.config_fail.add('alienware')
        result = c.manage(dict(action='start'), legacy)
        self.assertTrue(result['ok']); self.assertEqual(result['pending'], ['alienware'])
        self.assertNotIn(('alienware', 'start'), self.calls); self.assertNotIn(('alienware', 'activate'), self.calls)
        self.assert_live_graph('alienware-left', ['mac', 'x99'])
        status = c.manage(dict(action='status'), legacy)
        self.assertNotIn('alienware', status['ready']); self.assertTrue(status['input']['alienware']['layoutPending'])
        self.calls.clear(); self.config_fail.clear()
        c.manage(dict(action='start'), legacy)
        self.assert_live_graph('alienware-left', c.HOSTS)
        self.assertFalse(any(h == 'x99' and a != 'status' for h, a in self.calls))

    def test_readiness_failure_rebuilds_available_pair_with_bounded_attempts(self):
        legacy = self.fake_workers(); self.permission_fail.add('mac')
        with patch.object(c.time, 'monotonic', side_effect=range(0, 100, 4)):
            result = c.manage(dict(action='start'), legacy)
        self.assertTrue(result['ok']); self.assert_live_graph('alienware-left', ['x99','alienware'])
        self.assertEqual(self.calls.count(('mac', 'configure')), 1)
        self.assertEqual(self.calls.count(('x99', 'configure')), 2)

    def test_missing_permissions_never_interrupt_existing_deskflow(self):
        legacy = self.fake_workers(); self.permission_fail.update(['x99', 'alienware'])
        with patch.object(c.time, 'monotonic', side_effect=range(0, 100, 4)):
            result = c.manage(dict(action='start'), legacy)
        self.assertFalse(result['ok']); legacy.assert_not_called()
        self.assertFalse(c.session()['active'])

    def test_failed_activation_reconciles_remaining_pair(self):
        legacy = self.fake_workers(); self.activate_fail.add('mac')
        result = c.manage(dict(action='start'), legacy)
        self.assertTrue(result['ok']); self.assert_live_graph('alienware-left', ['x99', 'alienware'])
        self.assertEqual(self.calls.count(('mac', 'activate')), 1)

    def test_total_activation_failure_restores_legacy_and_marks_pending(self):
        legacy = self.fake_workers(); self.activate_fail.update(c.HOSTS)
        result = c.manage(dict(action='start'), legacy)
        self.assertFalse(result['ok']); self.assertFalse(c.session()['active'])
        self.assertEqual([call.args[0] for call in legacy.call_args_list][-2:],
                         [dict(action='stop'), dict(action='start', inputMode='deskflow')])
        self.assertEqual(result['pending'], list(c.HOSTS))

    def test_failed_active_layout_can_report_inactive_after_confirmed_cleanup(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        self.activate_fail.update(c.HOSTS)
        result = c.manage(dict(action='layout', layout='x99-left'), legacy)
        self.assertFalse(result['ok']); self.assertFalse(result['active'])
        self.assertEqual(result['unconfirmed'], [])
        self.assertFalse(c.session()['active'])
        self.assertEqual(self.live, {})
        legacy.assert_not_called()

    def test_lost_activation_and_stop_replies_preserve_possible_active_input(self):
        legacy = self.fake_workers()
        original = c.rpc.side_effect
        activation_attempted = set()
        def rpc(host, request):
            if request['action'] == 'stop' and host in activation_attempted:
                raise RuntimeError('stop unavailable')
            result = original(host, request)
            if request['action'] == 'activate':
                activation_attempted.add(host)
                raise RuntimeError('activation reply lost')
            return result
        c.rpc.side_effect = rpc
        result = c.manage(dict(action='start'), legacy)
        self.assertFalse(result['ok']); self.assertTrue(result['active'])
        self.assertEqual(set(result['unconfirmed']), set(c.HOSTS))
        self.assertTrue(c.session()['active'])
        self.assertEqual(set(self.live), set(c.HOSTS))
        # Do not restore competing legacy input while native activity is unknown.
        self.assertFalse(any(call.args[0].get('inputMode') == 'deskflow' for call in legacy.call_args_list))

    def test_pause_clears_only_confirmed_unresolved_activity(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        self.offline.update(['x99', 'alienware'])
        self.assertTrue(c.manage(dict(action='start'), legacy)['active'])
        paused = c.manage(dict(action='stop'), legacy)
        self.assertFalse(paused['ok']); self.assertTrue(paused['active'])
        self.assertEqual(paused['unconfirmed'], ['x99', 'alienware'])
        self.offline.clear()
        paused = c.manage(dict(action='stop'), legacy)
        self.assertTrue(paused['ok']); self.assertFalse(paused['active'])
        self.assertEqual(c.session()['unconfirmed'], [])
        self.offline.update(['x99', 'alienware'])
        result = c.manage(dict(action='start'), legacy)
        self.assertFalse(result['ok']); self.assertFalse(result['active'])

    def test_same_layout_request_reconciles_ring_without_poll_mutation(self):
        legacy = self.fake_workers(participants=c.HOSTS, legacy_ring=True)
        result = c.manage(dict(action='layout', layout='alienware-left'), legacy)
        self.assertTrue(result['ok']); self.assert_live_graph('alienware-left', c.HOSTS)

    def test_start_honors_changed_layout_when_already_active(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        result = c.manage(dict(action='start', layout='x99-left'), legacy)
        self.assertTrue(result['ok']); self.assert_live_graph('x99-left', c.HOSTS)

    def test_active_status_uses_incoming_alive_and_retains_layout(self):
        legacy = self.fake_workers(participants=c.HOSTS)
        original = c.rpc.side_effect
        def rpc(host, request):
            result = original(host, request)
            if host == 'mac':
                for peer in result['peers']: peer['alive'] = True
            return result
        c.rpc.side_effect = rpc
        result = c.manage(dict(action='status'), legacy)
        self.assertTrue(result['running']); self.assertFalse(result['partial'])
        self.assertEqual(result['layout'], 'alienware-left')
        self.assertEqual(result['connected'], sorted(c.HOSTS))
        self.assertEqual(set(a for _, a in self.calls), {'status'})

    def test_linux_local_worker_and_mac_remote_use_role_paths(self):
        with patch.object(c,'LOCAL_HOST','x99'),patch.object(c.subprocess,'run',return_value=Mock(stdout='{"ok":true}')) as run:
            c.rpc('x99',dict(action='status'))
            self.assertNotIn('ssh',run.call_args.args[0][0])
            self.assertTrue(run.call_args.args[0][1].endswith('.local/share/insight-notch/lan-mouse-worker.py'))
            c.rpc('mac',dict(action='status'))
            import base64
            command=run.call_args.args[0][-1]
            code=command.split("b64decode('")[1].split("')")[0]
            self.assertIn('pedro-notch/lan-mouse-worker.py',base64.b64decode(code).decode())

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

    def test_worker_reports_launch_digest_and_live_edge_after_profile_file_changes(self):
        original = c.topology('alienware-left', self.nodes)['x99']
        changed = c.topology('x99-left', self.nodes)['x99']
        w.save(w.BASE/'profile.json', original)
        launch_digest = w.profile_digest()
        self.assertEqual(launch_digest, c.digest(original))
        w.save(w.BASE/'session.json', dict(pid=1234, identity='owned', profileDigest=launch_digest))
        w.save(w.BASE/'profile.json', changed)
        events = [{'CaptureStatus': 'Enabled'}, {'EmulationStatus': 'Enabled'},
                  {'Enumerate': [[7, dict(hostname=None, fix_ips=self.nodes['mac']['ips'], pos='Left'),
                                  dict(active=True, alive=False)]]}]
        with patch.object(w, 'ipc', return_value=events), patch.object(w, 'process_identity', return_value='owned'):
            value = w.status()
        self.assertEqual(value['profileDigest'], launch_digest)
        self.assertEqual(value['peers'][0]['position'], 'left')
        self.assertTrue(c.matches(value, original))
        self.assertFalse(c.matches(value, changed))

    def test_pipes_stop_before_activation_and_pause_stops_both(self):
        legacy = self.fake_workers()
        def record(request):
            self.calls.append(('legacy', request['action']))
            return dict(ok=True)
        legacy.side_effect = record
        self.assertTrue(c.manage(dict(action='start'), legacy)['ok'])
        self.assertLess(self.calls.index(('legacy', 'start')), min(i for i, (_, a) in enumerate(self.calls) if a == 'activate'))
        self.calls.clear()
        self.assertTrue(c.manage(dict(action='stop'), legacy)['ok'])
        self.assertEqual({h for h, a in self.calls if a == 'stop'}, set(c.HOSTS) | {'legacy'})
        self.assertEqual(self.calls[-1], ('legacy', 'stop'))


if __name__ == '__main__':
    unittest.main()
