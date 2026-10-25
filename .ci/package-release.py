#!/usr/bin/env python3
"""Package all configured Libretro targets on CI and verify complete releases."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile

TARGETS = {
    'linux-x86_64': ('xenia_edge_libretro.so', 62),
    'linux-arm64': ('xenia_edge_libretro.so', 183),
    'windows-x86_64': ('xenia_edge_libretro.dll', 0x8664),
    'macos-arm64': ('xenia_edge_libretro.dylib', None),
    'android-arm64-v8a': ('xenia_edge_libretro_android.so', 183),
    'android-x86_64': ('xenia_edge_libretro_android.so', 62),
}
EXPORTS = ('retro_api_version', 'retro_get_system_info', 'retro_init', 'retro_deinit',
           'retro_load_game', 'retro_unload_game', 'retro_run', 'retro_serialize', 'retro_unserialize')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def archive_name(tag, target):
    return f'xenia_edge_libretro-{tag}-{target}.zip'


def verify_archive(archive, tag, target, source_commit):
    symbols = target.endswith('-symbols')
    base = target.removesuffix('-symbols')
    expected_payload = {'xenia_edge_libretro.pdb'} if symbols else {TARGETS[base][0], 'xenia_edge_libretro.info'}
    expected = expected_payload | {'build-manifest.json', 'README.txt', 'LICENSE', 'SHA256SUMS'}
    with zipfile.ZipFile(archive) as z:
        assert len(z.namelist()) == len(expected) and set(z.namelist()) == expected
        assert z.testzip() is None
        manifest = json.loads(z.read('build-manifest.json'))
        assert manifest['release'] == tag and manifest['commit'] == source_commit
        assert manifest['target'] == target and manifest['built_by'] == 'GitHub Actions'
        assert manifest['ci_run_id'] == os.environ['GITHUB_RUN_ID']
        assert manifest['ci_repository'] == os.environ['GITHUB_REPOSITORY']
        assert manifest['workflow_commit'] == os.environ['WORKFLOW_COMMIT']
        assert set(manifest['files']) == expected_payload
        for name, digest in manifest['files'].items():
            assert hashlib.sha256(z.read(name)).hexdigest() == digest, name
        checked = set()
        for line in z.read('SHA256SUMS').decode().splitlines():
            digest, name = line.split('  ', 1)
            assert name in expected - {'SHA256SUMS'} and name not in checked
            assert hashlib.sha256(z.read(name)).hexdigest() == digest, name
            checked.add(name)
        assert checked == expected - {'SHA256SUMS'}
    return manifest


def verify(directory, tag, source_commit, target=None, publication_status=None, assemble_checksums=False):
    desktop = [t for t in TARGETS if not t.startswith('android-')]
    android = [t for t in TARGETS if t.startswith('android-')]
    selected = [target] if target else desktop
    if target in (None, 'windows-x86_64'):
        selected.append('windows-x86_64-symbols')
    allowed = {archive_name(tag, t) for t in list(TARGETS) + ['windows-x86_64-symbols']}
    actual = {p.name for p in directory.iterdir()}
    assert actual <= allowed | {'SHA256SUMS'}, actual - allowed
    manifests = {t: verify_archive(directory / archive_name(tag, t), tag, t, source_commit) for t in selected}
    omitted = False
    reason = ''
    if not target:
        try:
            checked = {t: verify_archive(directory / archive_name(tag, t), tag, t, source_commit) for t in android}
        except (AssertionError, FileNotFoundError, zipfile.BadZipFile) as error:
            assert os.environ.get('ALLOW_ANDROID_FAILURE', '').lower() == 'true', f'Android incomplete: {error}'
            omitted = True
            reason = str(error)
            for t in android:
                (directory / archive_name(tag, t)).unlink(missing_ok=True)
            print('::warning::Android omitted under explicit authorization; all desktop packages remain mandatory.')
        else:
            manifests.update(checked)
            selected += android
    expected = {archive_name(tag, t) for t in selected}
    assert {p.name for p in directory.glob('*.zip')} == expected
    checksums = ''.join(f'{sha(directory / name)}  {name}\n' for name in sorted(expected))
    sums = directory / 'SHA256SUMS'
    if not target and assemble_checksums:
        sums.write_text(checksums)
    else:
        assert sums.read_text() == checksums
    if 'windows-x86_64-symbols' in manifests:
        core, symbols = manifests['windows-x86_64'], manifests['windows-x86_64-symbols']
        assert symbols['core_sha256'] == core['files']['xenia_edge_libretro.dll']
        assert symbols['ci_run_attempt'] == core['ci_run_attempt']
    result = {'published_targets': [t for t in selected if not t.endswith('-symbols')],
              'android_omitted': omitted, 'android_omission_reason': reason,
              'commit': source_commit, 'ci_run_id': os.environ['GITHUB_RUN_ID']}
    if publication_status:
        publication_status.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def native_abi(core, expected_version):
    class SystemInfo(ctypes.Structure):
        _fields_ = [('library_name', ctypes.c_char_p), ('library_version', ctypes.c_char_p),
                    ('valid_extensions', ctypes.c_char_p), ('need_fullpath', ctypes.c_bool),
                    ('block_extract', ctypes.c_bool)]
    library = ctypes.CDLL(str(core.resolve()))
    for symbol in EXPORTS:
        assert getattr(library, symbol)
    library.retro_api_version.restype = ctypes.c_uint
    assert library.retro_api_version() == 1
    info = SystemInfo()
    library.retro_get_system_info.argtypes = [ctypes.POINTER(SystemInfo)]
    library.retro_get_system_info(ctypes.byref(info))
    assert info.library_version.decode() == expected_version


def inspect(core, target, expected_version):
    if target == 'macos-arm64':
        subprocess.run(['codesign', '--verify', '--strict', str(core)], check=True)
        assert command('lipo', '-archs', str(core)) == 'arm64'
        dependencies = command('otool', '-L', str(core))
        assert '/opt/homebrew/' not in dependencies and '/usr/local/' not in dependencies
        native_abi(core, expected_version)
        return {'abi_validation': 'Native load, exported API, API version and source version',
                'dependencies': dependencies, 'compiler': command('clang++', '--version'),
                'sdk_version': command('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                'developer_directory': os.environ['DEVELOPER_DIR']}
    data = core.read_bytes()
    if target.startswith('windows-'):
        assert data[:2] == b'MZ'
        offset = struct.unpack_from('<I', data, 0x3C)[0]
        assert data[offset:offset + 4] == b'PE\0\0'
        assert struct.unpack_from('<H', data, offset + 4)[0] == TARGETS[target][1]
        native_abi(core, expected_version)
        return {'abi_validation': 'Native DLL load, exported API, API version and source version'}
    assert data[:6] == b'\x7fELF\x02\x01'
    assert struct.unpack_from('<H', data, 18)[0] == TARGETS[target][1]
    exports = command('readelf', '--dyn-syms', '--wide', str(core))
    for symbol in EXPORTS:
        assert re.search(r'\b' + symbol + r'\s*$', exports, re.M), symbol
    dependencies = command('readelf', '-d', str(core))
    if target.startswith('android-'):
        assert 'libc.so.6' not in dependencies and 'libstdc++.so.6' not in dependencies
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phentsize, phnum = struct.unpack_from('<HH', data, 54)
        for n in range(phnum):
            off = phoff + n * phentsize
            if struct.unpack_from('<I', data, off)[0] == 1:
                assert struct.unpack_from('<Q', data, off + 48)[0] >= 16384
        return {'abi_validation': 'Static ELF machine, exports, dependencies and 16 KiB alignment; Android runtime not exercised',
                'dependencies': dependencies, 'lto': False}
    native_abi(core, expected_version)
    return {'abi_validation': 'Native ELF load, exported API, API version and source version',
            'dependencies': dependencies, 'compiler': command('clang++-21', '--version')}


def make_archive(directory, tag, target, files, manifest):
    with tempfile.TemporaryDirectory(prefix='xenia-package-') as work:
        payload = Path(work)
        for path in files:
            shutil.copy2(path, payload / path.name)
        shutil.copy2('LICENSE', payload / 'LICENSE')
        manifest = dict(manifest, target=target, files={p.name: sha(p) for p in files})
        (payload / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        (payload / 'README.txt').write_text(
            f'Xenia Edge Libretro {tag}: {target}\n\n'
            'Install the core and matching .info in the directories configured by RetroArch.\n'
            'The symbols archive is for crash diagnosis, not installation as a core.\n'
            'Games, firmware, RetroArch and MoltenVK are not included.\n'
            'Build/API checks do not establish gameplay, audio or hardware compatibility.\n\n'
            f'Source: https://github.com/{os.environ["GITHUB_REPOSITORY"]}/releases/tag/{tag}\n'
            f'Built, packaged and published by: {manifest["ci_run_url"]}\n')
        (payload / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in sorted(payload.iterdir())))
        archive = directory / archive_name(tag, target)
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for p in sorted(payload.iterdir()):
                z.write(p, p.name)
    verify_archive(archive, tag, target, manifest['commit'])


def build(core, directory, tag, target, symbols):
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Release builds belong on GitHub Actions'
    assert core.name == TARGETS[target][0]
    commit = command('git', 'rev-parse', 'HEAD')
    assert commit == command('git', 'rev-parse', tag + '^{commit}')
    upstream = Path('upstream.version').read_text().strip()
    version = f'{upstream} (libretro core {commit[:7]})'
    validation = inspect(core, target, version)
    directory.mkdir(parents=True, exist_ok=True)
    assert not any(directory.iterdir())
    manifest = {'release': tag, 'commit': commit, 'upstream': upstream,
                'reported_library_version': version, 'lto': not target.startswith('android-'),
                'configuration': 'Release', 'built_by': 'GitHub Actions',
                'ci_repository': os.environ['GITHUB_REPOSITORY'],
                'ci_run_id': os.environ['GITHUB_RUN_ID'],
                'ci_run_attempt': os.environ['GITHUB_RUN_ATTEMPT'],
                'workflow_commit': os.environ['WORKFLOW_COMMIT'],
                'ci_run_url': f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
                **validation}
    make_archive(directory, tag, target, [core, Path('libretro/xenia_edge_libretro.info')], manifest)
    if target == 'windows-x86_64':
        assert symbols and symbols.is_file() and symbols.name == 'xenia_edge_libretro.pdb'
        make_archive(directory, tag, target + '-symbols', [symbols], dict(manifest, core_sha256=sha(core)))
    (directory / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in sorted(directory.glob('*.zip'))))
    verify(directory, tag, commit, target)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'verify'])
    parser.add_argument('--tag', required=True)
    parser.add_argument('--target', choices=TARGETS)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--core', type=Path)
    parser.add_argument('--symbols', type=Path)
    parser.add_argument('--source-commit')
    parser.add_argument('--publication-status', type=Path)
    parser.add_argument('--assemble-checksums', action='store_true')
    args = parser.parse_args()
    assert re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+', args.tag)
    if args.action == 'build':
        assert args.target and args.core and args.core.is_file()
        build(args.core, args.output, args.tag, args.target, args.symbols)
    else:
        assert args.source_commit
        verify(args.output, args.tag, args.source_commit, args.target, args.publication_status, args.assemble_checksums)
