"""Host requirements and host-native tools for iOS builds from Intel Macs."""
import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import build_app


class HostRules(unittest.TestCase):
    def test_ios_allows_intel_macos_156(self):
        build_app._check_host_platform('ios', 'Darwin', 'x86_64', '15.6.1')

    def test_ios_rejects_macos_before_156(self):
        with self.assertRaisesRegex(build_app.BuildError, '15.6 or later'):
            build_app._check_host_platform('ios', 'Darwin', 'x86_64', '15.5.9')

    def test_desktop_still_requires_apple_silicon_and_macos_26(self):
        with self.assertRaisesRegex(build_app.BuildError, 'Apple silicon'):
            build_app._check_host_platform('macos', 'Darwin', 'x86_64', '26.0')
        with self.assertRaisesRegex(build_app.BuildError, 'macOS 26 or later'):
            build_app._check_host_platform('macos', 'Darwin', 'arm64', '25.6.1')
        build_app._check_host_platform('macos', 'Darwin', 'arm64', '26.0')

    def test_prerequisites_defaults_missing_platform_to_desktop(self):
        with patch.object(build_app.platform, 'system', return_value='Darwin'), \
                patch.object(build_app.platform, 'machine', return_value='x86_64'), \
                self.assertRaisesRegex(build_app.BuildError, 'Apple silicon'):
            build_app.prerequisites(SimpleNamespace())

    def test_host_native_tools_use_expected_names(self):
        self.assertEqual(build_app.host_architecture('x86_64'), 'x86_64')
        self.assertEqual(build_app.dotnet_runtime_for_host('x86_64'), 'osx-x64')
        self.assertEqual(build_app.dotnet_runtime_for_host('arm64'), 'osx-arm64')
        self.assertEqual(build_app.translator_path(Path('/work'), 'x86_64'),
                         Path('/work/prebuilt/macos-x86_64/totk_xlate'))
        self.assertEqual(build_app.translator_path(Path('/work'), 'arm64'),
                         Path('/work/prebuilt/macos-arm64/totk_xlate'))


class IosToolchain(unittest.TestCase):
    def test_requires_full_xcode_26_device_sdk_and_metal_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            metal = Path(directory) / 'metal'
            metallib = Path(directory) / 'metallib'
            metal.touch()
            metallib.touch()
            responses = [
                subprocess.CompletedProcess([], 0, 'Xcode 26.0\nBuild version 17A', ''),
                subprocess.CompletedProcess([], 0, str(sdk), ''),
                subprocess.CompletedProcess([], 0, str(metal), ''),
                subprocess.CompletedProcess([], 0, str(metallib), ''),
            ]
            with patch.object(build_app.subprocess, 'run', side_effect=responses):
                build_app.check_ios_xcode_toolchain()

    def test_rejects_xcode_older_than_26(self):
        old_xcode = subprocess.CompletedProcess([], 0, 'Xcode 25.4\nBuild version 16F', '')
        with patch.object(build_app.subprocess, 'run', return_value=old_xcode):
            with self.assertRaisesRegex(build_app.BuildError, 'Xcode 26 or later'):
                build_app.check_ios_xcode_toolchain()


class HostTranslator(unittest.TestCase):
    def test_validates_the_host_architecture_copy_by_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            path = tree / 'prebuilt/macos-x86_64/totk_xlate'
            path.parent.mkdir(parents=True)
            path.write_bytes(b'intel translator')
            (path.parent / 'totk_xlate.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(build_app.check_translator(tree, 'x86_64'), path)
            path.write_bytes(b'changed translator')
            with self.assertRaisesRegex(build_app.BuildError, 'SHA-256-verified'):
                build_app.check_translator(tree, 'x86_64')

    def test_missing_host_copy_has_build_instructions(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(build_app.BuildError, 'publish_native.sh'):
                build_app.check_translator(Path(directory), 'x86_64')


class SpirvCrossHostBuild(unittest.TestCase):
    def test_compiles_for_the_macs_host_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            tree, logs = Path(directory) / 'tree', Path(directory) / 'logs'
            commands = []
            def record(cmd, log, **kwargs):
                commands.append([str(part) for part in cmd])

            with patch.object(build_app, 'host_architecture', return_value='x86_64'), \
                    patch.object(build_app, 'SPIRV_CROSS_SOURCES', ('spirv_cross.cpp',)), \
                    patch.object(build_app.os, 'cpu_count', return_value=1), \
                    patch.object(build_app, 'run', side_effect=record):
                build_app.build_spirv_cross(tree, logs)
            self.assertEqual(len(commands), 2)  # one compile and one link
            self.assertTrue(all(command[command.index('-arch') + 1] == 'x86_64' for command in commands))


class BinaryPreparation(unittest.TestCase):
    def test_device_path_prepares_game_data_and_icon_without_desktop_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tree, logs = root / 'tree', root / 'logs'
            (tree / 'build').mkdir(parents=True)
            commands = []
            def record(cmd, log, **kwargs):
                commands.append([str(part) for part in cmd])

            with patch.object(build_app, 'run', side_effect=record), \
                    patch.object(build_app, 'build_launcher', side_effect=AssertionError('desktop launcher built')), \
                    patch.object(build_app, 'build_warm_tool', side_effect=AssertionError('desktop warm tool built')), \
                    patch.object(build_app, 'say'):
                build_app.step_binary(tree, root / 'game.xci', root / 'prod.keys', {}, logs,
                                      version='v143', device_app=True)
            self.assertEqual(commands[0][:2], ['make', 'game-data-v143'])
            self.assertTrue(any('extract_app_icon.py' in part for part in commands[1]))
            self.assertFalse(any(command[0] == 'make' and 'runtime-v143' in command for command in commands))

    def test_desktop_path_still_builds_runtime_launcher_and_warm_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tree, logs = root / 'tree', root / 'logs'
            (tree / 'build').mkdir(parents=True)
            (tree / 'build/AppIcon.icns').write_bytes(b'icon')
            commands = []
            def record(cmd, log, **kwargs):
                commands.append([str(part) for part in cmd])

            with patch.object(build_app, 'run', side_effect=record), \
                    patch.object(build_app, 'build_launcher') as launcher, \
                    patch.object(build_app, 'build_warm_tool') as warm, \
                    patch.object(build_app, 'say'):
                build_app.step_binary(tree, root / 'game.xci', root / 'prod.keys', {}, logs, version='v143')
            self.assertEqual(commands[0][0], 'make')
            self.assertIn('runtime-v143', commands[0])
            launcher.assert_called_once()
            warm.assert_called_once()


if __name__ == '__main__':
    unittest.main()
