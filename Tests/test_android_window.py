import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('android_window',Path(__file__).resolve().parents[1]/'Integrations/android-window.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class AndroidWindowTests(unittest.TestCase):
    def test_invalid_identity_and_package_never_touch_files_or_adb(self):
        with patch.object(m,'call') as call:
            for ident,package in [('../outside','com.android.settings'),('a'*32,'../../outside'),('a'*32,'com.app;reboot')]:
                with self.assertRaises(ValueError):m.export_icon(ident,package,None)
            call.assert_not_called()

    def test_cached_original_icon_avoids_install_or_network(self):
        with tempfile.TemporaryDirectory() as root,patch.object(m,'ROOT',Path(root)),patch.object(m,'call') as call:
            cache=Path(root)/'android-icons'/('a'*32)/'com.android.settings';cache.mkdir(parents=True)
            (cache/'scrcpy.png').write_bytes(b'\x89PNG\r\n\x1a\noriginal')
            (cache/'meta.json').write_text(json.dumps({'name':'Configurações'}))
            meta,image=m.export_icon('a'*32,'com.android.settings',None)
            self.assertEqual(meta['name'],'Configurações');self.assertEqual(image.parent,cache)
            call.assert_not_called()

    def test_export_rejects_non_png_before_publishing_cache(self):
        with tempfile.TemporaryDirectory() as root,patch.object(m,'ROOT',Path(root)),patch.object(m.subprocess,'run') as run,patch.object(m,'call',side_effect=[b'Broadcast complete',b'{"name":"Settings"}',b'not a png']):
            run.return_value.stdout=b'package:installed.apk'
            with self.assertRaises(ValueError):m.export_icon('a'*32,'com.android.settings',{'transport':'trusted'})
            self.assertFalse(list(Path(root).rglob('scrcpy.png')))

    def test_readonly_vendor_binary_can_be_replaced(self):
        with tempfile.TemporaryDirectory() as root:
            source=Path(root)/"new";destination=Path(root)/"current"
            source.write_bytes(b"new binary");destination.write_bytes(b"old binary");destination.chmod(0o555)
            m.replace_binary(source,destination)
            self.assertEqual(destination.read_bytes(),b"new binary")

    def test_icon_bridge_is_shell_only_without_network_permission(self):
        manifest=(m.RES/'AndroidManifest.xml').read_text()
        self.assertIn('android.permission.DUMP',manifest)
        self.assertNotIn('uses-permission',manifest)

if __name__=='__main__':unittest.main()
