import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location('scrcpy_phone', Path(__file__).resolve().parents[1] / 'Integrations/scrcpy-phone.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class ScrcpyTests(unittest.TestCase):
    def test_tls_discovery_excludes_pairing_and_invalid_addresses(self):
        text = 'adb-A-xyz\t_adb-tls-connect._tcp\t192.168.0.1:1234\n' + 'studio-X\t_adb-tls-pairing._tcp\t192.168.0.1:4567\n' + 'bad\t_adb-tls-connect._tcp\tinvalid;command\n'
        self.assertEqual(m.services(text), [('adb-A-xyz', '192.168.0.1:1234')])

    def test_reconnect_only_learned_hardware_and_current_port(self):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            if args[-2:] == ['mdns', 'services']:
                return 'adb-SAVED-random\t_adb-tls-connect._tcp\t192.168.0.1:45678\n' + 'adb-OTHER-random\t_adb-tls-connect._tcp\t192.168.0.2:45679\n'
            return ''
        with patch.object(m, 'load', return_value={'id': {'hardware': 'SAVED'}}), patch.object(m, 'run', side_effect=run), patch.object(m, 'discover', return_value=[]):
            m.reconnect()
        self.assertIn([m.ADB, 'connect', '192.168.0.1:45678'], calls)
        self.assertNotIn([m.ADB, 'connect', '192.168.0.2:45679'], calls)

    def test_mdns_transport_is_not_duplicated_as_an_ip_transport(self):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            if args[-1] == 'devices': return 'adb-SAVED-random._adb-tls-connect._tcp device\n'
            if args[-2:] == ['mdns', 'services']: return 'adb-SAVED-random _adb-tls-connect._tcp 192.168.0.1:45678'
            return ''
        with patch.object(m, 'load', return_value={'id': {'hardware': 'SAVED'}}), patch.object(m, 'run', side_effect=run), patch.object(m, 'discover', return_value=[]):
            m.reconnect()
        self.assertFalse(any('connect' in args for args in calls))

    def test_bonjour_suffix_keeps_full_transport_and_service_name(self):
        serial = 'adb-SAVED-random (2)._adb-tls-connect._tcp'
        self.assertEqual(m.devices(serial + '\tdevice product:tablet\nold\toffline\n'), [serial])
        self.assertEqual(m.services('adb-SAVED-random (2) _adb-tls-connect._tcp 192.168.0.1:42911'),
                         [('adb-SAVED-random (2)', '192.168.0.1:42911')])

    def test_current_mdns_api_fallback_parses_tls_only(self):
        text = 'tls { service { instance: "adb-SAVED-random (2)" service: "_adb-tls-connect._tcp" ipv4: "192.168.0.1" port: 42911 } known_device: true }'
        self.assertEqual(m.tracked_services(text), [('adb-SAVED-random (2)', '192.168.0.1:42911')])
        self.assertEqual(m.tracked_services(text.replace('_adb-tls-connect', '_adb-tls-pairing')), [])
        proc = Mock(communicate=Mock(return_value=(text, '')))
        with patch.object(m, 'run', return_value=''), patch.object(m.subprocess, 'Popen', return_value=proc):
            self.assertEqual(m.mdns_services(), [('adb-SAVED-random (2)', '192.168.0.1:42911')])

    def test_duplicate_hardware_and_dead_transport_do_not_break_discovery(self):
        def run(args, **kwargs):
            if args[-1] == 'devices': return 'dead device\nadb-live (2)._adb-tls-connect._tcp device\nalias device\n'
            if args[2] == 'dead': raise m.subprocess.TimeoutExpired(args, 3)
            if args[-1] == 'ro.serialno': return 'TABLET'
            return 'SM-X806B'
        with patch.object(m, 'load', return_value={}), patch.object(m, 'save'), patch.object(m, 'run', side_effect=run):
            found = m.discover()
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][1]['transport'], 'adb-live (2)._adb-tls-connect._tcp')

    def test_launcher_output_indentation_and_real_app_labels(self):
        text = '2 activities found:\n Activity #0:\n    com.android.settings/.Settings\n Activity #1:\n    com.android.chrome/Main\n'
        self.assertEqual(m.app_packages(text), ['com.android.chrome','com.android.settings'])
        self.assertEqual(m.app_labels(' * Config.                        com.android.settings\n - WhatsApp                       com.whatsapp\n'), {'com.android.settings':'Config.','com.whatsapp':'WhatsApp'})

    def test_virtual_display_keeps_normal_close_and_distinct_lock(self):
        ident = next(iter(m.PROFILES))
        with tempfile.TemporaryDirectory() as root, patch.object(m, 'ROOT', Path(root)), patch.object(m, 'native_window', return_value=(m.SCRCPY,None,'Test')),  patch.object(m, 'reconnect', return_value=[(ident, {'transport':'known'})]), patch.object(m.subprocess, 'Popen', return_value=Mock(wait=Mock(return_value=0))) as call:
            m.mirror(ident,'com.android.settings')
            args=call.call_args.args[0]
            self.assertIn('--new-display=1280x960',args)
            self.assertIn('--flex-display',args)
            self.assertIn('--start-app=com.android.settings',args)
            self.assertNotIn('--no-vd-destroy-content',args)
            self.assertEqual(call.call_count,1)

    def test_user_close_does_not_reopen_and_disconnect_retries(self):
        ident = next(iter(m.PROFILES))
        for results in [[0], [1, 0]]:
            with self.subTest(results=results), tempfile.TemporaryDirectory() as root:
                children = [Mock(wait=Mock(return_value=code)) for code in results]
                with patch.object(m, 'ROOT', Path(root)), patch.object(m, 'native_window', return_value=(m.SCRCPY,None,'Test')),  patch.object(m, 'reconnect', return_value=[(ident, {'transport':'adb-known'})]), patch.object(m.subprocess, 'Popen', side_effect=children) as popen, patch.object(m.time, 'sleep'):
                    m.mirror(ident)
                    self.assertEqual(popen.call_count, len(results))
                    args = popen.call_args.args[0]
                    self.assertIn('--no-audio', args)
                    self.assertIn('--no-clipboard-autosync', args)
                    self.assertNotIn('--tcpip', args)

if __name__ == '__main__': unittest.main()
