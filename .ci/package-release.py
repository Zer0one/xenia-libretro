#!/usr/bin/env python3
"""Build and independently verify the macOS rolling package on CI runners."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def verify(directory, tag, source_commit):
    archive = directory / f'xenia_edge_libretro-{tag}-macos-arm64.zip'
    assert {p.name for p in directory.iterdir()} == {archive.name, 'SHA256SUMS'}
    assert (directory / 'SHA256SUMS').read_text() == f'{sha(archive)}  {archive.name}\n'
    expected = {'xenia_edge_libretro.dylib', 'xenia_edge_libretro.info',
                'build-manifest.json', 'README.txt', 'LICENSE', 'SHA256SUMS'}
    with zipfile.ZipFile(archive) as z:
        assert len(z.namelist()) == len(expected) and set(z.namelist()) == expected
        assert z.testzip() is None
        manifest = json.loads(z.read('build-manifest.json'))
        assert manifest['release'] == tag and manifest['commit'] == source_commit
        assert manifest['architecture'] == 'arm64' and manifest['built_by'] == 'GitHub Actions'
        assert manifest['ci_run_id'] == os.environ['GITHUB_RUN_ID']
        assert manifest['ci_run_attempt'] == os.environ['GITHUB_RUN_ATTEMPT']
        assert manifest['ci_repository'] == os.environ['GITHUB_REPOSITORY']
        assert set(manifest['files']) == {'xenia_edge_libretro.dylib', 'xenia_edge_libretro.info'}
        for name, digest in manifest['files'].items():
            assert hashlib.sha256(z.read(name)).hexdigest() == digest, name
        checksums = z.read('SHA256SUMS').decode().splitlines()
        assert len(checksums) == len(expected) - 1
        checked = set()
        for line in checksums:
            digest, name = line.split('  ', 1)
            assert name in expected - {'SHA256SUMS'} and name not in checked
            assert hashlib.sha256(z.read(name)).hexdigest() == digest, name
            checked.add(name)
        assert checked == expected - {'SHA256SUMS'}
    print(json.dumps({'archive': str(archive), 'sha256': sha(archive),
                      'commit': source_commit, 'ci_run_id': manifest['ci_run_id']}, indent=2))


def build(core_source, directory, tag):
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Release builds belong on GitHub Actions'
    commit = command('git', 'rev-parse', 'HEAD')
    assert commit == command('git', 'rev-parse', tag + '^{commit}')
    directory.mkdir(parents=True, exist_ok=True)
    assert not any(directory.iterdir())
    with tempfile.TemporaryDirectory(prefix='xenia-release-') as work:
        payload = Path(work)
        core = payload / 'xenia_edge_libretro.dylib'
        shutil.copy2(core_source, core)
        subprocess.run(['strip', '-x', str(core)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(core)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(core)], check=True)
        assert command('lipo', '-archs', str(core)) == 'arm64'
        dependencies = command('otool', '-L', str(core))
        assert '/opt/homebrew/' not in dependencies and '/usr/local/' not in dependencies
        class SystemInfo(ctypes.Structure):
            _fields_ = [('library_name', ctypes.c_char_p), ('library_version', ctypes.c_char_p),
                        ('valid_extensions', ctypes.c_char_p), ('need_fullpath', ctypes.c_bool),
                        ('block_extract', ctypes.c_bool)]
        library = ctypes.CDLL(str(core))
        library.retro_api_version.restype = ctypes.c_uint
        assert library.retro_api_version() == 1
        info = SystemInfo()
        library.retro_get_system_info.argtypes = [ctypes.POINTER(SystemInfo)]
        library.retro_get_system_info(ctypes.byref(info))
        upstream = Path('upstream.version').read_text().strip()
        assert info.library_version.decode() == f'{upstream} (libretro core {commit[:7]})'
        shutil.copy2('libretro/xenia_edge_libretro.info', payload)
        shutil.copy2('LICENSE', payload)
        manifest = {'release': tag, 'commit': commit, 'upstream': upstream,
                    'reported_library_version': info.library_version.decode(),
                    'architecture': 'arm64', 'minimum_macos': '15.0',
                    'configuration': 'Release', 'lto': True,
                    'compiler': command('clang++', '--version'),
                    'sdk_version': command('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                    'developer_directory': os.environ['DEVELOPER_DIR'],
                    'built_by': 'GitHub Actions', 'ci_repository': os.environ['GITHUB_REPOSITORY'],
                    'ci_run_id': os.environ['GITHUB_RUN_ID'],
                    'ci_run_attempt': os.environ['GITHUB_RUN_ATTEMPT'],
                    'workflow_commit': os.environ['WORKFLOW_COMMIT'],
                    'ci_run_url': f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
                    'files': {p.name: sha(p) for p in [core, payload / 'xenia_edge_libretro.info']}}
        (payload / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        (payload / 'README.txt').write_text(
            f'Xenia Edge Libretro {tag}\n\n'
            'Install the core and matching .info in RetroArch\'s configured core and info directories.\n'
            'Apple Silicon; macOS 15.0 or newer; use the Vulkan video driver.\n'
            'RetroArch, MoltenVK and games are not included.\n\n'
            f'Source and release: https://github.com/{os.environ["GITHUB_REPOSITORY"]}/releases/tag/{tag}\n'
            f'Built and packaged by: {manifest["ci_run_url"]}\n')
        (payload / 'SHA256SUMS').write_text(''.join(
            f'{sha(p)}  {p.name}\n' for p in sorted(payload.iterdir()) if p.is_file()))
        archive = directory / f'xenia_edge_libretro-{tag}-macos-arm64.zip'
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for p in sorted(payload.iterdir()):
                z.write(p, p.name)
        (directory / 'SHA256SUMS').write_text(f'{sha(archive)}  {archive.name}\n')
    verify(directory, tag, commit)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'verify'])
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--core', type=Path)
    parser.add_argument('--source-commit')
    args = parser.parse_args()
    assert re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+', args.tag)
    if args.action == 'build':
        assert args.core and args.core.is_file()
        build(args.core, args.output, args.tag)
    else:
        assert args.source_commit
        verify(args.output, args.tag, args.source_commit)
