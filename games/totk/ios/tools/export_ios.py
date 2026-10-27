#!/usr/bin/env python3
"""Patch verified game bytes with the shared native patcher and export iOS code segments."""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / 'runtime'
PAGE_SIZE = 0x4000
MODULES = ('main', 'subsdk0', 'sdk')
VERSIONS = ('v0', 'v112', 'v121', 'v143', 'botw160', 'botw190')
TABLE_HEADER = struct.Struct('<8s8sIIQQQQQ')
TABLE_MODULE = struct.Struct('<16s72s13Q4I')
TABLE_SYMBOL = struct.Struct('<QQI4B')
TABLE_RELOC = struct.Struct('<QIIq')
TABLE_GATE = struct.Struct('<QQII')


class ExportError(RuntimeError):
    """Invalid or unsupported iOS export inputs."""


def page_up(value: int) -> int:
    return (value + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)


def _table_range(size: int, offset: int, count: int, item_size: int) -> bool:
    return offset % 8 == 0 and offset <= size and count <= (size - offset) // item_size


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _verified_image(item: dict) -> bytes:
    """Read one module snapshot and verify the exact bytes that will be used."""
    try:
        image = item['path'].read_bytes()
    except OSError as error:
        raise ExportError(f'cannot read verified rewrite {item["path"]}: {error}') from error
    if len(image) != item['file_size']:
        raise ExportError(f'{item["name"]} image size changed during export')
    if hashlib.sha256(image).hexdigest() != item['digest']:
        raise ExportError(f'{item["name"]} image SHA256 changed during export')
    return image


def load_export_plan(game_data: Path, rewritten: Path, version: str) -> list[dict]:
    """Mirror loader.c's structural, image-hash, and iOS segment-layout guards.

    Strong import resolution remains authoritative in the device loader.
    """
    if version not in VERSIONS:
        raise ExportError(f'unsupported iOS export version: {version}')
    tables_path = game_data / 'runtime-tables.bin'
    try:
        table_data = tables_path.read_bytes()
    except OSError as error:
        raise ExportError(f'cannot read verified runtime tables {tables_path}: {error}') from error
    if not TABLE_HEADER.size <= len(table_data) < (1 << 30):
        raise ExportError('game tables size')

    magic, table_version, module_count, table_format, _plt, _slot, strings_off, strings_size, table_size = TABLE_HEADER.unpack_from(table_data)
    if magic != b'TOTKTAB1' or table_format != 1 or table_size != len(table_data):
        raise ExportError('game tables format')
    expected_version = version.encode('ascii').ljust(8, b'\0')
    if table_version != expected_version:
        raise ExportError(f'game tables are for {table_version.split(bytes([0]), 1)[0].decode("ascii", "replace")}, not {version}')
    if module_count != len(MODULES) or not _table_range(len(table_data), TABLE_HEADER.size, module_count, TABLE_MODULE.size):
        raise ExportError('game tables module layout')
    if strings_size == 0 or not _table_range(len(table_data), strings_off, strings_size, 1) or table_data[strings_off + strings_size - 1] != 0:
        raise ExportError('game tables strings layout')

    plan = []
    for index, expected_name in enumerate(MODULES):
        record_off = TABLE_HEADER.size + index * TABLE_MODULE.size
        fields = TABLE_MODULE.unpack_from(table_data, record_off)
        raw_name, raw_digest = fields[:2]
        (file_size, text_end, ro_off, data_off, patch_off, key_off, _init, _ctor_flag,
         _init_array, _init_size, symbols_off, relocs_off, gates_off,
         symbol_count, reloc_count, gate_count, _reserved) = fields[2:]
        if raw_name[-1] != 0 or raw_name.split(b'\0', 1)[0].decode('ascii', 'replace') != expected_name:
            raise ExportError('game tables module')
        digest = raw_digest.split(b'\0', 1)[0]
        if len(digest) != 64:
            raise ExportError('game tables module digest')
        if not _table_range(len(table_data), symbols_off, symbol_count, TABLE_SYMBOL.size):
            raise ExportError('game tables symbol bounds')
        if not _table_range(len(table_data), relocs_off, reloc_count, TABLE_RELOC.size):
            raise ExportError('game tables relocation bounds')
        if not _table_range(len(table_data), gates_off, gate_count, TABLE_GATE.size):
            raise ExportError('game tables gate bounds')

        for symbol_index in range(symbol_count):
            symbol_off = symbols_off + symbol_index * TABLE_SYMBOL.size
            _value, _size, name_off, _defined, _binding, _type, _reserved = TABLE_SYMBOL.unpack_from(table_data, symbol_off)
            if name_off >= strings_size:
                raise ExportError('game tables symbol name')

        gate_returns = []
        for gate_index in range(gate_count):
            gate_off = gates_off + gate_index * TABLE_GATE.size
            ret, _original, _timer, _arg = TABLE_GATE.unpack_from(table_data, gate_off)
            gate_returns.append(ret)
        if len(set(gate_returns)) != gate_count:
            raise ExportError('game tables: two gates with one return address')

        for reloc_index in range(reloc_count):
            reloc_off = relocs_off + reloc_index * TABLE_RELOC.size
            where, kind, symbol_index, addend = TABLE_RELOC.unpack_from(table_data, reloc_off)
            if (where < data_off or where > key_off or key_off - where < 8 or
                    symbol_index >= symbol_count):
                raise ExportError('game tables relocation bounds')
            if kind not in (257, 1025, 1026, 1027):
                raise ExportError('game tables relocation kind')
            if kind == 1027 and not 0 <= addend < key_off:
                raise ExportError('game tables relative addend')

        image_path = rewritten / f'{expected_name}.patched.bin'
        try:
            image_size = image_path.stat().st_size
        except OSError as error:
            raise ExportError(f'cannot stat verified rewrite {image_path}: {error}') from error
        if image_size != file_size:
            raise ExportError(f'{expected_name} patched module size differs from verified rewrite')
        if _digest(image_path) != digest.decode('ascii', 'replace'):
            raise ExportError(f'{expected_name} image SHA256 differs from verified rewrite')

        padded_file_size = page_up(file_size)
        x0_size = page_up(text_end)
        module_size = padded_file_size + (PAGE_SIZE if expected_name == 'main' else 0)
        if (not file_size or text_end > file_size or x0_size > patch_off or
                patch_off > padded_file_size or key_off % PAGE_SIZE or
                key_off + PAGE_SIZE > patch_off or patch_off >= module_size):
            raise ExportError(f'{expected_name} key and iOS segment layout')
        plan.append({
            'name': expected_name,
            'path': image_path,
            'digest': digest.decode('ascii', 'replace'),
            'file_size': file_size,
            'text_end': text_end,
            'ro_off': ro_off,
            'data_off': data_off,
            'patch_off': patch_off,
            'key_off': key_off,
            'x0_size': x0_size,
            'padded_file_size': padded_file_size,
        })
    return plan


def module_segments(image: bytes, text_end: int, patch_off: int) -> tuple[bytes, bytes]:
    """Return the exact x0 text and x1 patch-area ranges consumed by gen_embed.py."""
    x0_size = page_up(text_end)
    padded_file_size = page_up(len(image))
    if text_end > len(image) or x0_size > patch_off or patch_off > padded_file_size:
        raise ExportError('embedded module layout')
    padded = image + bytes(padded_file_size - len(image))
    return padded[:x0_size], padded[patch_off:padded_file_size]


def _patcher_for(version: str) -> tuple[list[str], Path]:
    if version in ('v0', 'v112', 'v121'):
        define = {'v0': None, 'v112': 'TOTK_GAME_V112', 'v121': 'TOTK_GAME_V121'}[version]
        return ([f'-D{define}=1'] if define else []), RUNTIME / 'game_patches.c'
    if version == 'v143':
        return ['-DTOTK_GAME_V143=1'], RUNTIME / 'game_patches_v143.c'
    if version == 'botw160':
        return ['-DGAME_BOTW160=1', '-DGAME_BOTW=1'], RUNTIME / 'game_patches_botw.c'
    if version == 'botw190':
        return ['-DGAME_BOTW190=1', '-DGAME_BOTW=1'], RUNTIME / 'game_patches_botw.c'
    raise ExportError(f'unsupported iOS export version: {version}')


def _run_shared_patcher(plan: list[dict], version: str, env: dict[str, str]) -> bytes:
    clang = shutil.which('clang')
    if not clang:
        raise ExportError('native clang is required to build the host-side iOS export helper')
    main = plan[0]
    main_snapshot = _verified_image(main)
    patch_defines, patcher_source = _patcher_for(version)
    with tempfile.TemporaryDirectory(prefix='totk-ios-export-') as temp_dir:
        temp = Path(temp_dir)
        helper = temp / 'export-ios-helper'
        verified_main = temp / 'main.verified.bin'
        verified_main.write_bytes(main_snapshot)
        patched_main = temp / 'main.patched.bin'
        command = [clang, '-std=c11', '-O1', '-DTOTK_EXPORT_ONLY=1', *patch_defines,
                   '-I', str(RUNTIME), str(Path(__file__).with_name('export_ios.c')),
                   str(patcher_source), '-lm', '-o', str(helper)]
        subprocess.run(command, cwd=ROOT, env=env, check=True)
        subprocess.run([str(helper), str(verified_main), str(patched_main),
                        str(main['file_size']), str(main['text_end']), str(main['ro_off']),
                        str(main['data_off']), str(main['patch_off']), str(main['key_off'])],
                       cwd=ROOT, env=env, check=True)
        try:
            result = patched_main.read_bytes()
        except OSError as error:
            raise ExportError(f'host patch helper did not write the patched main image: {error}') from error
        if len(result) != main['file_size']:
            raise ExportError('host patch helper returned an image with the wrong size')
        return result


def export_ios(version: str, rewritten: Path, game_data: Path, out: Path, env: dict[str, str] | None = None) -> None:
    plan = load_export_plan(game_data, rewritten, version)
    child_env = dict(os.environ if env is None else env)
    if child_env.get('TOTK_SURVEY') == '1':
        raise ExportError('TOTK_SURVEY=1 is unsupported by the export-only helper')
    if version == 'v143' and child_env.get('TOTK_ASPECT_VERT') == '1':
        raise ExportError('TOTK_ASPECT_VERT=1 is unsupported by the iOS runtime; unset it to export the supported screen-fit path')
    out.mkdir(parents=True, exist_ok=True)
    child_env['TOTK_EXPORT_IOS'] = str(out.resolve())
    patched_main = _run_shared_patcher(plan, version, child_env)
    for item in plan:
        image = patched_main if item['name'] == 'main' else _verified_image(item)
        x0, x1 = module_segments(image, item['text_end'], item['patch_off'])
        if len(x0) != item['x0_size'] or item['patch_off'] + len(x1) != item['padded_file_size']:
            raise ExportError(f'{item["name"]} embedded module layout')
        (out / f'{item["name"]}.x0.bin').write_bytes(x0)
        (out / f'{item["name"]}.x1.bin').write_bytes(x1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', choices=VERSIONS, required=True)
    parser.add_argument('--rewritten', type=Path, required=True)
    parser.add_argument('--game-data', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    export_ios(args.version, args.rewritten, args.game_data, args.out)


if __name__ == '__main__':
    main()
