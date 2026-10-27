"""The Intel-host iOS exporter preserves the runtime loader's image and segment guards."""
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'games/totk/ios/tools'
sys.path.insert(0, str(TOOLS))
import export_ios  # noqa: E402


def fixture_tree(root, *, bad_layout=False, main_symbols=(), main_relocs=(), main_gates=()):
    game_data = root / 'build/game-data/v143'
    rewritten = root / 'rewritten/v143'
    game_data.mkdir(parents=True)
    rewritten.mkdir(parents=True)
    images = {}
    for name in export_ios.MODULES:
        image = (bytes(range(256)) * 0x91)[:0x9001]
        image = bytes([len(name)]) + image[1:]
        images[name] = image
        (rewritten / f'{name}.patched.bin').write_bytes(image)

    records_off = export_ios.TABLE_HEADER.size + len(export_ios.MODULES) * export_ios.TABLE_MODULE.size
    cursor = records_off
    arrays = {}
    module_arrays = {}
    for name in export_ios.MODULES:
        source = {
            'symbols': main_symbols if name == 'main' else (),
            'relocs': main_relocs if name == 'main' else (),
            'gates': main_gates if name == 'main' else (),
        }
        module_arrays[name] = {}
        for kind, entries in source.items():
            cursor = (cursor + 7) & ~7
            offset = cursor
            if kind == 'symbols':
                data = b''.join(export_ios.TABLE_SYMBOL.pack(*entry) for entry in entries)
            elif kind == 'relocs':
                data = b''.join(export_ios.TABLE_RELOC.pack(*entry) for entry in entries)
            else:
                data = b''.join(export_ios.TABLE_GATE.pack(*entry) for entry in entries)
            arrays[offset] = data
            cursor += len(data)
            module_arrays[name][kind] = (offset, len(entries))
    strings_off = (cursor + 7) & ~7
    table_size = strings_off + 1
    records = []
    for name in export_ios.MODULES:
        image = images[name]
        patch_off = 0x3000 if bad_layout and name == 'main' else 0x8000
        symbols_off, symbol_count = module_arrays[name]['symbols']
        relocs_off, reloc_count = module_arrays[name]['relocs']
        gates_off, gate_count = module_arrays[name]['gates']
        q_fields = (len(image), 0x3000, 0x3000, 0x3000, patch_off, 0x4000,
                    0, 0, 0, 0, symbols_off, relocs_off, gates_off)
        digest = hashlib.sha256(image).hexdigest().encode('ascii').ljust(72, b'\0')
        records.append(export_ios.TABLE_MODULE.pack(name.encode().ljust(16, b'\0'), digest,
                                                     *q_fields, symbol_count, reloc_count, gate_count, 0))
    table_data = bytearray(table_size)
    for offset, data in arrays.items():
        table_data[offset:offset + len(data)] = data
    header = export_ios.TABLE_HEADER.pack(b'TOTKTAB1', b'v143'.ljust(8, b'\0'), 3, 1,
                                          0, 0, strings_off, 1, table_size)
    table_data[:export_ios.TABLE_HEADER.size] = header
    record_start = export_ios.TABLE_HEADER.size
    table_data[record_start:record_start + len(records) * export_ios.TABLE_MODULE.size] = b''.join(records)
    table_data[strings_off] = 0
    (game_data / 'runtime-tables.bin').write_bytes(table_data)
    return game_data, rewritten, images


class ExportInputGuards(unittest.TestCase):
    def test_rejects_a_main_digest_that_does_not_match_the_verified_tables(self):
        with tempfile.TemporaryDirectory() as temp:
            game_data, rewritten, _ = fixture_tree(Path(temp))
            main = rewritten / 'main.patched.bin'
            main.write_bytes(b'X' + main.read_bytes()[1:])
            with self.assertRaisesRegex(export_ios.ExportError, 'main image SHA256'):
                export_ios.load_export_plan(game_data, rewritten, 'v143')

    def test_rejects_segment_layout_that_overlaps_text_and_patch_area(self):
        with tempfile.TemporaryDirectory() as temp:
            game_data, rewritten, _ = fixture_tree(Path(temp), bad_layout=True)
            with self.assertRaisesRegex(export_ios.ExportError, 'main key and iOS segment layout'):
                export_ios.load_export_plan(game_data, rewritten, 'v143')

    def test_rechecks_main_digest_before_passing_a_snapshot_to_the_shared_patcher(self):
        with tempfile.TemporaryDirectory() as temp:
            game_data, rewritten, _ = fixture_tree(Path(temp))
            plan = export_ios.load_export_plan(game_data, rewritten, 'v143')
            main = rewritten / 'main.patched.bin'
            main.write_bytes(b'X' + main.read_bytes()[1:])
            with self.assertRaisesRegex(export_ios.ExportError, 'main image SHA256 changed'):
                export_ios._run_shared_patcher(plan, 'v143', {})

    def test_rechecks_non_main_digest_before_exporting_its_segments(self):
        with tempfile.TemporaryDirectory() as temp:
            game_data, rewritten, _ = fixture_tree(Path(temp))
            plan = export_ios.load_export_plan(game_data, rewritten, 'v143')
            sdk = rewritten / 'sdk.patched.bin'
            sdk.write_bytes(b'X' + sdk.read_bytes()[1:])
            with self.assertRaisesRegex(export_ios.ExportError, 'sdk image SHA256 changed'):
                export_ios._verified_image(plan[2])

    def test_rejects_survey_mode_instead_of_silently_ignoring_it(self):
        with tempfile.TemporaryDirectory() as temp:
            game_data, rewritten, _ = fixture_tree(Path(temp))
            with self.assertRaisesRegex(export_ios.ExportError, 'TOTK_SURVEY=1'):
                export_ios.export_ios('v143', rewritten, game_data, Path(temp) / 'out', {'TOTK_SURVEY': '1'})

    def test_rejects_malformed_symbol_relocation_and_gate_records(self):
        valid_symbol = ((0, 0, 0, 0, 0, 0, 0),)
        cases = (
            ('symbol name outside strings',
             {'main_symbols': ((0, 0, 1, 0, 0, 0, 0),)}, 'game tables symbol name'),
            ('duplicate gate return address',
             {'main_gates': ((0x100, 0, 0, 0), (0x100, 0, 0, 0))},
             'game tables: two gates with one return address'),
            ('relocation before data',
             {'main_symbols': valid_symbol, 'main_relocs': ((0x2ff8, 257, 0, 0),)},
             'game tables relocation bounds'),
            ('relocation extends beyond key page',
             {'main_symbols': valid_symbol, 'main_relocs': ((0x4000, 257, 0, 0),)},
             'game tables relocation bounds'),
            ('relocation symbol index outside table',
             {'main_symbols': valid_symbol, 'main_relocs': ((0x3000, 257, 1, 0),)},
             'game tables relocation bounds'),
            ('unsupported relocation kind',
             {'main_symbols': valid_symbol, 'main_relocs': ((0x3000, 999, 0, 0),)},
             'game tables relocation kind'),
            ('negative relative addend',
             {'main_symbols': valid_symbol, 'main_relocs': ((0x3000, 1027, 0, -1),)},
             'game tables relative addend'),
            ('relative addend reaches key page',
             {'main_symbols': valid_symbol, 'main_relocs': ((0x3000, 1027, 0, 0x4000),)},
             'game tables relative addend'),
        )
        for label, table_entries, message in cases:
            with self.subTest(record=label), tempfile.TemporaryDirectory() as temp:
                game_data, rewritten, _ = fixture_tree(Path(temp), **table_entries)
                with self.assertRaisesRegex(export_ios.ExportError, message):
                    export_ios.load_export_plan(game_data, rewritten, 'v143')


class ExportSegments(unittest.TestCase):
    def test_text_and_patch_area_are_page_sized_and_keep_their_exact_ranges(self):
        image = (bytes(range(256)) * 0x91)[:0x9001]
        x0, x1 = export_ios.module_segments(image, 0x3000, 0x8000)
        self.assertEqual(len(x0), 0x4000)
        self.assertEqual(x0, image[:0x4000])
        self.assertEqual(len(x1), 0x4000)
        self.assertEqual(x1[:0x1001], image[0x8000:])
        self.assertEqual(x1[0x1001:], bytes(0x2fff))


def synthetic_v143_main(path, *, corrupt_fps=False):
    file_size = 0x2900000
    text_end = 0x25ff000
    patch_off = 0x2800000
    key_off = 0x27fc000
    image = bytearray(file_size)
    words = {
        0x3e5658: 0x1e210808,
        0x2daa54: 0xbd425260,
        0x2daa58: 0x52a84e08,
        0x2daa6c: 0x5e21d800,
        0x2daa70: 0x1e201820,
        0x2daa74: 0x1e2c1001,
        0x2daa78: 0x1e210800,
        0x585e48: 0x1e220160,
        0x585e50: 0xbd0cc660,
        0x585e54: 0x1e220140,
        0x585e60: 0xbd0cca60,
        0x628c74: 0xbd400000,
        0xb43460: 0xbd400000,
        0x1ff04f4: 0xbd400000,
        0x253fbb0: 0xbd400000,
        0x2db204: 0x6b08015f,
        0x2db208: 0x1a89b10a,
        0x2db22c: 0xb940468a,
        0x2db360: 0x6b0801bf,
        0x2db36c: 0x1a88c1ac,
        0x2db340: 0xb9400288,
        0x2db34c: 0x2a0a03f5,
        0x246eac: 0x1e200940,
        0x345904: 0x1e210801,
        0x24944c: 0x94015e7d,
        0x28bc98: 0x9400546a,
    }
    if corrupt_fps:
        words[0x2db204] ^= 1
    for offset, word in words.items():
        struct.pack_into('<I', image, offset, word)
    path.write_bytes(image)
    return {
        'name': 'main',
        'path': path,
        'digest': hashlib.sha256(image).hexdigest(),
        'file_size': file_size,
        'text_end': text_end,
        'ro_off': 0x2600000,
        'data_off': 0x2640000,
        'patch_off': patch_off,
        'key_off': key_off,
    }


def adrp_word(register, pc_offset, target_offset):
    pages = (target_offset >> 12) - (pc_offset >> 12)
    immediate = pages & 0x1fffff
    return 0x90000000 | ((immediate & 3) << 29) | ((immediate >> 2) << 5) | register


def patcher_test_env(temp):
    env = os.environ.copy()
    for name in tuple(env):
        if name.startswith('TOTK_'):
            env.pop(name)
    env.update(TMPDIR=str(temp), TOTK_EXPORT_IOS=str(temp), TOTK_HIGHFPS_FIX='0')
    return env


@unittest.skipUnless(shutil.which('clang'), 'the host-native export helper requires clang')
class SharedPatcherIntegration(unittest.TestCase):
    def test_compiled_shared_patcher_rejects_an_original_instruction_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            main = synthetic_v143_main(Path(temp) / 'main.patched.bin', corrupt_fps=True)
            env = patcher_test_env(temp)
            original_run = export_ios.subprocess.run

            def capture_run(*args, **kwargs):
                kwargs.setdefault('capture_output', True)
                return original_run(*args, **kwargs)

            with mock.patch.object(export_ios.subprocess, 'run', side_effect=capture_run):
                with self.assertRaises(subprocess.CalledProcessError) as failure:
                    export_ios._run_shared_patcher([main], 'v143', env)
            self.assertIn(b'1.4.3 FPS patch original instruction mismatch', failure.exception.stderr)

    def test_compiled_shared_patcher_emits_page_relative_adrp_words(self):
        with tempfile.TemporaryDirectory() as temp:
            main = synthetic_v143_main(Path(temp) / 'main.patched.bin')
            env = patcher_test_env(temp)
            patched = export_ios._run_shared_patcher([main], 'v143', env)
            stub = main['text_end']
            data = export_ios.page_up(main['file_size'])
            for offset, register in ((stub, 8), (stub + 176, 8), (0x585e48, 3)):
                with self.subTest(offset=hex(offset)):
                    self.assertEqual(struct.unpack_from('<I', patched, offset)[0],
                                     adrp_word(register, offset, data))


if __name__ == '__main__':
    unittest.main()
