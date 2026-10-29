"""games/totk/ios/tools/build_ipa.py: what an iOS build leaves out of the way and copies (2026-10-23)."""
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parents[1]/'games/totk/ios/tools'
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(ROOT))
import build_ipa  # noqa: E402
import install_device  # noqa: E402
import build_app  # noqa: E402


class Discard(unittest.TestCase):
    def test_a_folder_is_moved_aside_at_once_and_deleted_later(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); old = root/'TOTK.app'
            (old/'GameData/shader-seed').mkdir(parents=True)
            for i in range(50):
                (old/f'GameData/shader-seed/{i}.metallib').write_bytes(b'x')
            build_ipa.discard(old)
            self.assertFalse(old.exists())   # the path is free for the new build right away
            for _ in range(100):
                if not any(root.iterdir()):
                    break
                time.sleep(0.05)
            self.assertEqual(list(root.iterdir()), [])   # and the moved folder is gone once the background delete ran

    def test_a_missing_path_is_fine(self):
        with tempfile.TemporaryDirectory() as d:
            build_ipa.discard(Path(d)/'none')


class SeedBeside(unittest.TestCase):
    """--ios-game-data documents leaves the startup shaders beside the output; the README installs the .ipa, and the
    seed was pushed only for an .app folder, so the game said 'No shaders' after a successful install."""
    def layout(self, root, output):
        (root/'Tears of the Kingdom-shader-seed').mkdir()
        (root/'Tears of the Kingdom-shader-seed/fingerprint.txt').write_text('f' * 64)
        app = root/'signed/Payload/TOTK.app'; (app/'GameData').mkdir(parents=True)
        return root/output, app

    def test_an_ipa_gets_its_seed(self):
        with tempfile.TemporaryDirectory() as d:
            ipa, app = self.layout(Path(d), 'Tears of the Kingdom.ipa'); ipa.write_bytes(b'PK')
            self.assertEqual(install_device.seed_beside(ipa, app), Path(d)/'Tears of the Kingdom-shader-seed')

    def test_an_app_folder_gets_its_seed(self):
        with tempfile.TemporaryDirectory() as d:
            out, app = self.layout(Path(d), 'Tears of the Kingdom.app'); out.mkdir()
            self.assertEqual(install_device.seed_beside(out, out), Path(d)/'Tears of the Kingdom-shader-seed')

    def test_an_app_that_carries_its_seed_gets_none(self):
        with tempfile.TemporaryDirectory() as d:
            ipa, app = self.layout(Path(d), 'Tears of the Kingdom.ipa'); (app/'GameData/shader-seed').mkdir()
            self.assertIsNone(install_device.seed_beside(ipa, app))


def read_pack(parts):
    """ios/Sources/main.m seed_unpack, in Python: the files of a pack stream cut into parts."""
    data = b''.join(p.read_bytes() for p in parts); assert data[:9] == b'TOTKPACK1'; at, out = 9, {}
    while True:
        nl = int.from_bytes(data[at:at + 2], 'little'); at += 2
        if not nl: return out, at == len(data)
        name = data[at:at + nl].decode(); at += nl
        size = int.from_bytes(data[at:at + 8], 'little'); at += 8
        out[name] = data[at:at + size]; at += size


class ShaderPack(unittest.TestCase):
    def test_files_come_back_whole_across_part_boundaries(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); seed = root/'seed'; seed.mkdir(); parts = []
            files = {'a.metal': b'x' * 1000, 'b.json': b'{}', 'empty.variants': b'', 'c.metallib': bytes(range(256)) * 3}
            for n, b in files.items():
                (seed/n).write_bytes(b)
            install_device.write_pack(seed, sorted(files), root, 'shader-seed-x', 97, parts.append)
            self.assertGreater(len(parts), 10)   # cut in the middle of names, sizes and contents
            self.assertTrue(all(p.stat().st_size <= 97 for p in parts))
            got, exact = read_pack(parts)
            self.assertEqual(got, files)
            self.assertTrue(exact)   # nothing after the end mark

class DeviceSeedPush(unittest.TestCase):
    def test_seed_presence_covers_app_owned_and_legacy_layouts(self):
        folder = 'shader-seed-fingerprint-123'
        with mock.patch.object(install_device, 'device_files', return_value={'seed-manifest.json': 1}) as listing:
            self.assertTrue(install_device.seed_on_device('device', 'bundle', folder, {}, {}))
            listing.assert_called_once_with('device', 'bundle', f'Documents/shader-seeds/{folder}')
        self.assertTrue(install_device.seed_on_device('device', 'bundle', folder, {}, {f'{folder}.pack.000': 1}))
        self.assertTrue(install_device.seed_on_device('device', 'bundle', folder, {folder: 1}, {}))
        self.assertTrue(install_device.seed_on_device('device', 'bundle', folder, {f'{folder}.pack.000': 1}, {}))
        self.assertFalse(install_device.seed_on_device('device', 'bundle', '../seed', {}, {f'../seed.pack.000': 1}))

    def test_push_skips_matching_completed_and_staged_seeds(self):
        folder, fingerprint = 'shader-seed-fingerprint-123', 'f' * 64
        layouts = (
            ({}, {f'{folder}.pack.000': 1}, {}),                       # new Documents pack
            ({f'{folder}.pack.000': 1}, {}, {}),                       # legacy GameData pack
            ({}, {}, {'seed-manifest.json': 1}),                       # app-owned completed seed
        )
        with tempfile.TemporaryDirectory() as d:
            seed = Path(d)/'seed'; seed.mkdir()
            (seed/'fingerprint.txt').write_text(fingerprint)
            for game_data, documents, relocated in layouts:
                with self.subTest(game_data=game_data, documents=documents, relocated=relocated):
                    def read_marker(cmd, **kwargs):
                        Path(cmd[cmd.index('--destination') + 1]).write_text(f'{folder}\n{fingerprint}\n')
                        return mock.Mock(returncode=0)

                    def listing(_dev, _bundle, subdirectory):
                        return {'Documents/GameData': game_data, 'Documents': documents,
                                f'Documents/shader-seeds/{folder}': relocated,
                                f'Documents/{folder}': {}}.get(subdirectory, {})

                    with mock.patch.object(install_device.subprocess, 'run', side_effect=read_marker), \
                         mock.patch.object(install_device, 'device_files', side_effect=listing), \
                         mock.patch.object(install_device, 'write_pack') as pack:
                        install_device.push_seed('device', 'bundle', seed)
                    pack.assert_not_called()

    def test_push_stages_parts_in_documents_and_keeps_the_marker_in_gamedata(self):
        with tempfile.TemporaryDirectory() as d:
            seed = Path(d)/'seed'; seed.mkdir()
            (seed/'fingerprint.txt').write_text('f' * 64)
            (seed/'a.metal').write_bytes(b'abc')
            copies = []

            def fake_pack(source, names, folder, stem, size, done):
                part = Path(folder)/f'{stem}.pack.000'
                part.write_bytes(b'pack')
                done(part)

            def fake_run(cmd, **kwargs):
                copies.append(cmd)

            with mock.patch.object(install_device, 'device_files', return_value={}), \
                 mock.patch.object(install_device.subprocess, 'run', return_value=mock.Mock(returncode=1)), \
                 mock.patch.object(install_device, 'run', side_effect=fake_run), \
                 mock.patch.object(install_device, 'write_pack', side_effect=fake_pack):
                install_device.push_seed('device', 'bundle', seed)

            destinations = [cmd[cmd.index('--destination') + 1] for cmd in copies]
            self.assertEqual(destinations[0], 'Documents/GameData/shader-seed.txt')
            self.assertRegex(destinations[1], r'^Documents/shader-seed-f{12}-\d+\.pack\.000$')
            self.assertEqual(destinations[2], 'Documents/GameData/shader-seed.txt')



class FullHD(unittest.TestCase):
    """The TOTK menu's Display choice uses the existing Settings.bundle key and is applied before game startup."""
    def test_switch_off_by_default_and_docked_at_1600x900(self):
        import plistlib
        ios = TOOLS.parent
        specs = plistlib.loads((ios/'Settings.bundle/Root.plist').read_bytes())['PreferenceSpecifiers']
        switch = [s for s in specs if s.get('Key') == 'TOTK_DOCKED']
        self.assertEqual(len(switch), 1)
        self.assertIs(switch[0]['DefaultValue'], False)
        main = (ios/'Sources/main.m').read_text()
        helper_start = main.index('static void apply_totk_display_preferences')
        helper_end = main.index('\n#endif', helper_start)
        helper = main[helper_start:helper_end]
        self.assertIn('boolForKey:@"TOTK_DOCKED"', helper)
        for line in ('"TOTK_OPERATION_MODE", "docked"', '"TOTK_OPERATION_MODE", "handheld"',
                     '"TOTK_IOS_DRAWABLE_H", "1080"', '"TOTK_RENDER_RES", "1600x900"'):
            self.assertIn(line, helper)
        helper_guard = main.rfind('#if !TARGET_OS_VISION && !defined(GAME_BOTW)', 0, helper_start)
        self.assertGreaterEqual(helper_guard, 0)

        play_start = main.index('menu.playHandler = ^{')
        play_end = main.index('self.window.rootViewController = menu;', play_start)
        play_handler = main[play_start:play_end]
        self.assertLess(play_handler.index('apply_totk_display_preferences();'), play_handler.index('TOTKGameController *game'))
        finish = main.index('- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:')
        self.assertNotIn('boolForKey:@"TOTK_DOCKED"', main[finish:], 'the menu choice must be read after launch')
        self.assertIn('#ifdef GAME_BOTW\n    /* Breath of the Wild has no docked choice', main[finish:])

        menu = (ios/'Sources/main_menu.m').read_text()
        self.assertIn('@[@"Handheld (720p)", @"Docked (1080p)"]', menu)
        self.assertIn('setBool:control.selectedSegmentIndex == 1 forKey:@"TOTK_DOCKED"', menu)
        build = (TOOLS/'build_ipa.py').read_text()
        self.assertIn("s.get('Key')=='TOTK_DOCKED'", build)
        self.assertIn("'      - path: Gen/Settings.bundle'", build)


class MenuControllerNavigation(unittest.TestCase):
    """Menu controller polling stays active only on the launcher and covers every visible control."""
    @classmethod
    def setUpClass(cls):
        cls.menu = (TOOLS.parent/'Sources/main_menu.m').read_text()

    def test_tabs_use_shoulders_and_reset_focus_to_first_setting(self):
        focus_list = self.menu[self.menu.index('- (NSArray<UIControl *> *)controllerSettingsItems {'):
                               self.menu.index('- (NSArray<UIControl *> *)activeControllerItems {')]
        self.assertIn('self.settingsPageControllerItems[self.selectedSettingsTab]', focus_list)
        self.assertIn('[items addObject:self.settingsCloseButton]', focus_list)
        self.assertNotIn('settingsTabButtons', focus_list)
        self.assertIn('@[gyroRow, hapticsRow, swapControllerLayoutRow]', self.menu)
        self.assertIn('scrollRectToVisible:', self.menu)

        poll = self.menu[self.menu.index('- (void)pollController {'):
                         self.menu.index('- (void)playTapped:', self.menu.index('- (void)pollController {'))]
        self.assertIn('gamepad.leftShoulder.isPressed', poll)
        self.assertIn('gamepad.rightShoulder.isPressed', poll)
        self.assertIn('[self moveSettingsTab:shoulderRight ? 1 : -1];', poll)
        tab_start = self.menu.index('- (void)settingsTabTapped:(UIButton *)sender {')
        tab_end = self.menu.index('\n- (NSInteger)iosMasterVolumePreference {', tab_start)
        tab_handler = self.menu[tab_start:tab_end]
        self.assertIn('self.settingsFocusIndex = 0;', tab_handler)
        self.assertIn('self.selectedSettingsTab = selected;', tab_handler)

    def test_dpad_and_stick_navigate_and_change_values_with_a_and_b_actions(self):
        poll = self.menu[self.menu.index('- (void)pollController {'):
                         self.menu.index('- (void)playTapped:', self.menu.index('- (void)pollController {'))]
        self.assertIn('gamepad.dpad.up.isPressed', poll)
        self.assertIn('gamepad.dpad.down.isPressed', poll)
        self.assertIn('gamepad.leftThumbstick.xAxis.value', poll)
        self.assertIn('gamepad.leftThumbstick.yAxis.value', poll)
        self.assertIn('BOOL activate = gamepad.buttonA.isPressed;', poll)
        self.assertIn('BOOL back = gamepad.buttonB.isPressed;', poll)
        self.assertIn('[self closeSettings];', poll)
        self.assertIn('sendActionsForControlEvents:UIControlEventValueChanged', self.menu)
        self.assertIn('sendActionsForControlEvents:UIControlEventTouchUpInside', self.menu)
        self.assertIn('BOOL shouldBeOn = direction > 0;', self.menu)
        self.assertIn('slider.value + (float)direction * 5.0f', self.menu)
        self.assertIn('if (!any) { self.controllerInputHeld = NO; return; }', poll)

    def test_controller_layout_toggle_persists_and_only_describes_gameplay_mapping(self):
        self.assertIn('isEnabled:[NSUserDefaults.standardUserDefaults boolForKey:@"TOTK_SWAP_CONTROLLER_LAYOUT"]', self.menu)
        self.assertIn('detail:@"Swaps physical A/B and X/Y buttons during gameplay only. Menu and touch controls are unchanged."', self.menu)
        self.assertIn('action:@selector(swapControllerLayoutRowTapped:)', self.menu)
        swap_handler = self.menu[self.menu.index('- (void)swapControllerLayoutRowTapped:'):
                                 self.menu.index('- (void)setPreferenceToggleRow:')]
        self.assertIn('key:@"TOTK_SWAP_CONTROLLER_LAYOUT"', swap_handler)
        toggle_handler = self.menu[self.menu.index('- (void)setPreferenceToggleRow:'):
                                   self.menu.index('- (void)settingsScrimTapped:')]
        self.assertIn('BOOL enabled = !toggle.isOn;', toggle_handler)
        self.assertIn('[NSUserDefaults.standardUserDefaults setBool:enabled forKey:key];', toggle_handler)
        self.assertIn('setenv(key.UTF8String, enabled ? "1" : "0", 1);', toggle_handler)

    def test_launcher_focus_uses_fill_and_restores_unfocused_colors(self):
        button = self.menu[self.menu.index('- (UIButton *)makeMenuButton:'):
                           self.menu.index('- (void)viewDidLayoutSubviews')]
        self.assertIn('BOOL focused = weakSelf.controllerFocusedView == updatedButton;', button)
        self.assertIn('updated.baseForegroundColor = dark;', button)
        self.assertIn('updated.background.backgroundColor = focusGold;', button)
        self.assertIn('updatedButton.isHighlighted ? [base colorWithAlphaComponent:0.72] : base', button)
        self.assertIn('configuration.background.backgroundColor', button)

    def test_focus_debounces_held_inputs_and_stops_when_the_menu_leaves(self):
        self.assertIn('ring.borderWidth = 3;', self.menu)
        self.assertIn('[view.layer addSublayer:ring];', self.menu)
        self.assertIn('if (!any) { self.controllerInputHeld = NO; return; }', self.menu)
        self.assertIn('if (self.controllerInputHeld) return;', self.menu)
        self.assertIn('self.controllerInputHeld = YES; // Require one neutral sample after launch or foregrounding.', self.menu)
        self.assertIn('self.controllerInputHeld = YES; // A held button on a reconnect cannot activate the menu immediately.', self.menu)
        self.assertIn('if (!gamepad) {', self.menu)
        self.assertIn('shoulderLeft || shoulderRight', self.menu)
        for method in ('viewWillDisappear:', 'applicationWillResignActive:', 'sceneWillDeactivate:', 'playTapped:'):
            start = self.menu.index('- (void)' + method)
            end = self.menu.find('\n- (', start + 5)
            if end == -1: end = len(self.menu)
            self.assertIn('[self stopControllerPolling];', self.menu[start:end], method)
        self.assertIn('!self.lastPolledController || !items.count', self.menu)


class MenuVideo(unittest.TestCase):
    def test_video_is_added_as_a_quoted_resource_for_totk_ios(self):
        with tempfile.TemporaryDirectory() as d:
            video = Path(d)/'folder with "quotes" #1'/'totk_menu_video.mp4'
            video.parent.mkdir(); video.write_bytes(b'video')
            source = 'targets:\n  TOTKIOS:\n    sources:\n      - Sources\n'
            generated = build_ipa.project_with_menu_video(source, video, platform='ios', is_botw=False)
            self.assertIn(f'      - path: {json.dumps(str(video.resolve()))}\n', generated)
            self.assertIn('        buildPhase: resources\n', generated)
            self.assertEqual(generated.count('totk_menu_video.mp4'), 1)

    def test_video_is_excluded_for_visionos_and_botw(self):
        with tempfile.TemporaryDirectory() as d:
            video = Path(d)/'totk_menu_video.mp4'; video.write_bytes(b'video')
            source = 'targets:\n  TOTKIOS:\n    sources:\n      - Sources\n'
            for platform, is_botw in (('visionos', False), ('ios', True)):
                with self.subTest(platform=platform, is_botw=is_botw):
                    self.assertEqual(build_ipa.project_with_menu_video(
                        source, video, platform=platform, is_botw=is_botw), source)

    def test_missing_explicit_video_fails_and_absent_optional_video_is_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            missing = Path(d)/'totk_menu_video.mp4'
            with self.assertRaisesRegex(RuntimeError, '--menu-video must name an existing file'):
                build_ipa.resolve_menu_video(missing)
            self.assertIsNone(build_ipa.resolve_menu_video(None))

    def test_default_asset_is_passed_only_for_totk_ios_when_present(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); video = root/'game_essentials/totk_menu_video.mp4'
            video.parent.mkdir(); video.write_bytes(b'video')
            self.assertEqual(build_app.ios_menu_video_args('totk', 'ios', root),
                             ['--menu-video', str(video.resolve())])
            self.assertEqual(build_app.ios_menu_video_args('totk', 'visionos', root), [])
            self.assertEqual(build_app.ios_menu_video_args('botw', 'ios', root), [])
            self.assertEqual(build_app.ios_menu_video_args('totk', 'ios', root/'missing'), [])


if __name__ == '__main__':
    unittest.main()
