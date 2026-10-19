"""Source/build preconditions only; never imports an input worker or starts capture."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'Integrations/lan-mouse-capture/build.py'
spec = importlib.util.spec_from_file_location('capture_build', SCRIPT)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

class CaptureBuildTests(unittest.TestCase):
    def test_exact_functional_patch_is_required(self):
        original = build.PATCH.read_bytes()
        build.validate_patch(original)
        with self.assertRaises(ValueError):
            build.validate_patch(original.replace(b'inner.read();', b'inner.read();\n+                inner.read();'))

    def test_refuses_wrong_base_before_patch_or_cargo(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(build, 'git', return_value='other') as git:
            with self.assertRaises(ValueError):
                build.verify_source(Path(tmp))
            self.assertEqual(git.call_count, 1)

    def test_refuses_unrelated_changes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(build, 'git', side_effect=[build.BASE, ' M src/main.rs']):
            with self.assertRaises(ValueError):
                build.verify_source(Path(tmp))

    def test_cargo_commands_are_pinned_offline_headless_units_only(self):
        commands = build.cargo_commands('cargo')
        self.assertEqual(len(commands), 3)
        for command in commands:
            self.assertIn('--locked', command)
            self.assertIn('--offline', command)
            self.assertIn('--no-default-features', command)
            self.assertIn('--release', command)
        self.assertEqual(commands[0][1], 'build')
        self.assertIn(build.FEATURES, commands[0])
        self.assertIn('--bin', commands[1])
        self.assertIn('--lib', commands[2])
        self.assertNotIn('--workspace', sum(commands, []))

if __name__ == '__main__':
    unittest.main()
