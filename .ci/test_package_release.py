#!/usr/bin/env python3
"""Test publication gates with synthetic archives; no core builds or game data."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('release_package', Path(__file__).with_name('package-release.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PublicationGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {'GITHUB_RUN_ID': 'unit-test-run',
            'GITHUB_REPOSITORY': 'test/repository', 'WORKFLOW_COMMIT': 'tools-sha',
            'ALLOW_ANDROID_FAILURE': 'false'})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.tag = 'v0.1.0.1'
        self.commit = 'source-sha'
        self.targets = list(package.TARGETS) + ['windows-x86_64-symbols']

    def archive(self, target, **changes):
        symbols = target.endswith('-symbols')
        filename = 'xenia_edge_libretro.pdb' if symbols else package.TARGETS[target][0]
        payload = {filename: f'binary:{target}'.encode()}
        if not symbols:
            payload['xenia_edge_libretro.info'] = b'info fixture'
        digest = lambda data: hashlib.sha256(data).hexdigest()
        manifest = {'release': self.tag, 'commit': self.commit, 'target': target,
            'built_by': 'GitHub Actions', 'ci_repository': 'test/repository',
            'ci_run_id': 'unit-test-run', 'ci_run_attempt': '1',
            'workflow_commit': 'tools-sha', 'files': {n: digest(b) for n, b in payload.items()}}
        if symbols:
            manifest['core_sha256'] = digest(b'binary:windows-x86_64')
        manifest.update(changes)
        payload.update({'build-manifest.json': json.dumps(manifest).encode(),
                        'README.txt': b'test fixture', 'LICENSE': b'test fixture'})
        payload['SHA256SUMS'] = ''.join(f'{digest(b)}  {n}\n' for n, b in sorted(payload.items())).encode()
        path = self.directory / package.archive_name(self.tag, target)
        with zipfile.ZipFile(path, 'w') as z:
            for name, data in payload.items():
                z.writestr(name, data)
        return path

    def all_archives(self):
        for target in self.targets:
            self.archive(target)

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            package.verify(self.directory, self.tag, self.commit, assemble_checksums=True)

    def test_complete_set_is_required_and_accepted(self):
        self.all_archives()
        self.verify()
        self.assertEqual(7, len((self.directory / 'SHA256SUMS').read_text().splitlines()))

    def test_missing_desktop_blocks_even_with_android_permission(self):
        self.all_archives()
        (self.directory / package.archive_name(self.tag, 'linux-arm64')).unlink()
        os.environ['ALLOW_ANDROID_FAILURE'] = 'true'
        with self.assertRaises(FileNotFoundError):
            self.verify()
        self.assertFalse((self.directory / 'SHA256SUMS').exists())

    def test_desktop_only_policy_accepts_desktop_and_symbols_without_android(self):
        for target in self.targets:
            if not target.startswith('android-'):
                self.archive(target)
        status = self.directory.parent / (self.directory.name + '-status.json')
        self.addCleanup(lambda: status.unlink(missing_ok=True))
        with contextlib.redirect_stdout(io.StringIO()):
            package.verify(self.directory, self.tag, self.commit, desktop_only=True,
                           publication_status=status, assemble_checksums=True)
        self.assertEqual(5, len((self.directory / 'SHA256SUMS').read_text().splitlines()))
        self.assertTrue(json.loads(status.read_text())['android_excluded'])

    def test_desktop_only_policy_rejects_unexpected_android_archives(self):
        self.all_archives()
        with self.assertRaises(AssertionError), contextlib.redirect_stdout(io.StringIO()):
            package.verify(self.directory, self.tag, self.commit, desktop_only=True,
                           assemble_checksums=True)
        self.assertFalse((self.directory / 'SHA256SUMS').exists())

    def test_missing_android_blocks_without_permission(self):
        self.all_archives()
        (self.directory / package.archive_name(self.tag, 'android-x86_64')).unlink()
        with self.assertRaises(AssertionError):
            self.verify()

    def test_authorized_android_failure_omits_both_android_targets(self):
        self.all_archives()
        (self.directory / package.archive_name(self.tag, 'android-x86_64')).unlink()
        os.environ['ALLOW_ANDROID_FAILURE'] = 'true'
        self.verify()
        self.assertEqual(5, len((self.directory / 'SHA256SUMS').read_text().splitlines()))
        self.assertFalse((self.directory / package.archive_name(self.tag, 'android-arm64-v8a')).exists())

    def test_downloaded_checksum_is_verified_not_rewritten(self):
        self.all_archives()
        self.verify()
        (self.directory / 'SHA256SUMS').write_text('corrupt checksum\n')
        with self.assertRaises(AssertionError), contextlib.redirect_stdout(io.StringIO()):
            package.verify(self.directory, self.tag, self.commit)

    def test_wrong_source_blocks_publication(self):
        self.all_archives()
        self.archive('macos-arm64', commit='other-source')
        with self.assertRaises(AssertionError):
            self.verify()

    def test_wrong_ci_provenance_blocks_publication(self):
        self.all_archives()
        self.archive('windows-x86_64', ci_run_id='another-run')
        with self.assertRaises(AssertionError):
            self.verify()

    def test_symbols_for_another_dll_are_rejected(self):
        self.all_archives()
        self.archive('windows-x86_64-symbols', core_sha256='another-dll')
        with self.assertRaises(AssertionError):
            self.verify()


if __name__ == '__main__':
    unittest.main()
