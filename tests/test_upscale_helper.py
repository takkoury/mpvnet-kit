"""CPU-only model, component publication and Windows process ownership checks."""
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from zipfile import ZipFile, ZipInfo

from support.dev_imports import DEV_TOOLS
import managed_build


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'trt-10.16-test'
SPAN_ASSET = 'upscale/models/nomosuni-span-multijpg-ldl-2x-v1.onnx'
VAPOURSYNTH = 'runtime/Lib/site-packages/vapoursynth/'
MEMBERS = (
    'runtime/python.exe', 'runtime/python3.dll', 'runtime/python312.dll', 'runtime/python312.zip',
    VAPOURSYNTH + 'vsscript.dll', VAPOURSYNTH + 'libvapoursynth.dll', VAPOURSYNTH + 'vapoursynth.pyd',
    'plugins/vstrt.dll', 'plugins/vsmlrt-cuda/trtexec.exe', 'models/cugan.onnx', 'models/esrgan.onnx',
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(os.name == 'nt', 'Requires Windows and local .NET Framework reference assemblies')
class UpscaleHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix='kit-upscale-')
        cls.addClassCleanup(temporary.cleanup)
        cls.directory = Path(temporary.name)
        build = runpy.run_path(str(Path(DEV_TOOLS) / 'build-upscale-helper.py'))
        dotnet, compiler, _ = managed_build.compiler()
        references = cls.directory / 'refs'
        references.mkdir()
        for name, data in managed_build.reference_snapshot(build['FRAMEWORK_VERSION'], build['REFERENCE_FILES']).items():
            (references / name).write_bytes(data)
        cls.probe = cls.directory / 'UpscaleHelperProbe.exe'
        compiled = subprocess.run([
            dotnet, str(compiler), '-nologo', '-noconfig', '-nostdlib+', '-utf8output', '-codepage:65001',
            '-langversion:7.3', '-warnaserror+', '-target:exe', '-main:UpscaleHelperProbe',
            f'-out:{cls.probe}', *(f'-reference:{path}' for path in sorted(references.iterdir())),
            *(str(ROOT / path) for path in build['SOURCE_FILES'] if path.endswith('.cs')),
            str(ROOT / 'tests/fixtures/upscale_helper_probe.cs'),
        ], capture_output=True, timeout=30)
        if compiled.returncode:
            raise AssertionError((compiled.stdout + compiled.stderr).decode('utf-8-sig'))

    def fixture(self, label):
        root = self.directory / label
        helpers = root / 'helpers'
        helpers.mkdir(parents=True)
        (root / 'upscale').mkdir()
        (root / 'archives').mkdir()
        exe = helpers / self.probe.name
        shutil.copyfile(self.probe, exe)
        return root, exe

    def test_progress_publication_tolerates_a_brief_reader(self):
        root, exe = self.fixture('progress')
        result = subprocess.run([str(exe), 'atomic-read', str(root / 'progress.json')],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertEqual(json.loads(result.stdout), {'phase': 'updated'})

    @staticmethod
    def write_manifest(root, *, linked_member=False):
        archives = []
        expected = {}

        def archive(name, archive_format, members):
            data = (root / 'archives' / name).read_bytes()
            archives.append(dict(name=name, format=archive_format, url='https://www.python.org/' + name,
                                 sha256=sha256(data), size=len(data), extract=members))

        fake_tool = b'placeholder archive unpacker; never executed'
        (root / 'archives/7zr.exe').write_bytes(fake_tool)
        expected['tools/7zr.exe'] = fake_tool
        archive('7zr.exe', 'raw', [dict(source='7zr.exe', target='tools/7zr.exe', size=len(fake_tool))])
        files = []
        with ZipFile(root / 'archives/runtime.zip', 'w') as zip_file:
            for path in MEMBERS:
                content = path.encode('utf-8')
                info = ZipInfo(path)
                if linked_member and path == 'runtime/python.exe':
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                zip_file.writestr(info, content)
                expected[path] = content
                files.append(dict(source=path, target=path, size=len(content)))
        archive('runtime.zip', 'zip', files)
        pth_path, pth = 'runtime/python312._pth', 'python312.zip\n.\nLib/site-packages\n'
        expected[pth_path] = pth.encode('utf-8')
        data = json.dumps(dict(
            schema=1, bundle_id=BUNDLE_ID, archives=archives,
            download_bytes=sum(item['size'] for item in archives),
            expanded_bytes=sum(map(len, expected.values())),
            generated_files=[dict(path=pth_path, text=pth, size=len(pth), sha256=sha256(pth.encode()))],
        )).encode()
        (root / 'upscale/components.json').write_bytes(data)
        return data, expected

    @staticmethod
    def request(root, parent_pid=None, *, operation='install', **fields):
        request_path = root / 'request.json'
        request_path.write_text(json.dumps(dict(
            schema=1, request_id='upscale-cpu', operation=operation,
            parent_pid=parent_pid or os.getpid(), config_root=str(root),
            progress_path=str(request_path) + '.status.json', **fields,
        )), encoding='utf-8')
        return request_path

    def invoke(self, root, exe, action, **fields):
        completed = subprocess.run([str(exe), action, str(self.request(root, **fields))], capture_output=True, timeout=15)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors='replace'))
        return json.loads(completed.stdout)

    @staticmethod
    def component_root(root):
        return root / 'components/ai-upscale'

    def install_model_fixture(self, root, exe):
        _, expected = self.write_manifest(root)
        catalog = json.loads((ROOT / 'config/upscale/models.json').read_text(encoding='utf-8'))
        for definition in catalog['models'].values():
            if definition['source'] == 'bundle':
                definition['sha256'] = sha256(expected[definition['path']])
        (root / 'upscale/models.json').write_text(json.dumps(catalog), encoding='utf-8')
        self.assertEqual(self.invoke(root, exe, 'install'), {'ready': True})
        return catalog

    def prepare_model(self, root, exe, model, **fields):
        return self.invoke(root, exe, 'prepare', operation='prepare', model=model, width=641, height=479, **fields)

    def test_span_asset_errors_leave_runtime_and_legacy_models_available(self):
        root, exe = self.fixture('span-status')
        self.install_model_fixture(root, exe)
        receipt = self.component_root(root) / 'component.json'
        receipt_bytes = receipt.read_bytes()
        span = root / SPAN_ASSET
        model_data = (ROOT / 'config' / SPAN_ASSET).read_bytes()
        span.parent.mkdir()

        for reason, data in (
            ('model_missing', None),
            ('model_integrity', bytes([model_data[0] ^ 1]) + model_data[1:]),
            (None, model_data),
        ):
            with self.subTest(reason=reason):
                if data is not None:
                    span.write_bytes(data)
                self.assertEqual(self.invoke(root, exe, 'probe', operation='probe'), {
                    'component_ready': True, 'model_errors': {'SPAN': reason} if reason else {},
                })
                self.assertEqual(self.prepare_model(root, exe, 'CUGAN'), {
                    'padded_width': 644, 'padded_height': 480,
                })
                self.assertEqual(self.prepare_model(root, exe, 'ESRGAN'), {
                    'padded_width': 641, 'padded_height': 479,
                })
                self.assertEqual(self.prepare_model(root, exe, 'SPAN'), {
                    'error_reason': reason,
                } if reason else {'padded_width': 641, 'padded_height': 479})
                self.assertEqual(receipt.read_bytes(), receipt_bytes)

    def test_model_paths_are_confined_to_their_managed_directory(self):
        root, exe = self.fixture('span-path')
        catalog = self.install_model_fixture(root, exe)
        alternate = root / 'alternate'
        alternate.mkdir()
        span = root / SPAN_ASSET
        replacement = alternate / span.name
        shutil.copyfile(ROOT / 'config' / SPAN_ASSET, replacement)
        self.assertEqual(self.prepare_model(root, exe, 'SPAN', model_path=str(replacement)),
                         {'error_reason': 'model_missing'})
        self.assertEqual(self.prepare_model(root, exe, 'external'), {'error_reason': 'unsupported_input'})

        for path in (str(replacement), 'upscale/models/../../alternate/' + span.name):
            with self.subTest(path=path):
                catalog['models']['SPAN']['path'] = path
                (root / 'upscale/models.json').write_text(json.dumps(catalog), encoding='utf-8')
                self.assertEqual(self.prepare_model(root, exe, 'SPAN'), {'error_reason': 'model_integrity'})

        catalog['models']['SPAN']['path'] = SPAN_ASSET
        (root / 'upscale/models.json').write_text(json.dumps(catalog), encoding='utf-8')
        subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/j', str(span.parent), str(alternate)],
                       check=True, capture_output=True, timeout=10)
        try:
            self.assertEqual(self.invoke(root, exe, 'probe', operation='probe'), {
                'component_ready': True, 'model_errors': {'SPAN': 'model_integrity'},
            })
        finally:
            span.parent.rmdir()

    def test_receipt_matches_manifest_and_rejects_modified_component(self):
        root, exe = self.fixture('receipt')
        manifest, expected = self.write_manifest(root)
        self.assertEqual(self.invoke(root, exe, 'install'), {'ready': True})
        components = self.component_root(root)
        receipt_path = components / 'component.json'
        receipt_bytes = receipt_path.read_bytes()
        receipt = json.loads(receipt_bytes)
        self.assertEqual((receipt['schema'], receipt['bundle_id'], receipt['manifest_sha256']),
                         (1, BUNDLE_ID, sha256(manifest)))
        self.assertEqual({row['path']: (row['size'], row['sha256']) for row in receipt['files']},
                         {path: (len(data), sha256(data)) for path, data in expected.items()})
        self.assertEqual(self.invoke(root, exe, 'install'), {'ready': True})
        self.assertEqual(receipt_path.read_bytes(), receipt_bytes)
        model = components / 'bundles' / BUNDLE_ID / 'models/cugan.onnx'
        model.write_bytes(expected['models/cugan.onnx'].upper())
        self.assertEqual(self.invoke(root, exe, 'check'), {'ready': False})

    def test_failed_extraction_cleans_staging_and_preserves_conflicts(self):
        root, exe = self.fixture('failure')
        self.write_manifest(root, linked_member=True)
        components = self.component_root(root)
        bundle = components / 'bundles' / BUNDLE_ID
        receipt = components / 'component.json'
        self.assertEqual(self.invoke(root, exe, 'install'), {'error_reason': 'bundle_integrity'})
        self.assertFalse(bundle.exists())
        self.assertFalse(receipt.exists())
        self.assertEqual(list((components / 'staging').iterdir()), [])

        bundle.mkdir(parents=True)
        unknown = bundle / 'external.txt'
        unknown.write_bytes(b'unmanaged data')
        self.write_manifest(root)
        self.assertEqual(self.invoke(root, exe, 'install'), {'error_reason': 'bundle_conflict'})
        self.assertEqual(unknown.read_bytes(), b'unmanaged data')
        self.assertFalse(receipt.exists())

    def test_owned_job_reaps_child_tree_on_cancel_and_parent_exit(self):
        kernel = ctypes.WinDLL('kernel32.dll', use_last_error=True)
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel.TerminateProcess.argtypes = (wintypes.HANDLE, wintypes.UINT)

        for cause in ('marker', 'parent-exit'):
            with self.subTest(cause=cause):
                root, exe = self.fixture(cause)
                owner = subprocess.Popen([sys.executable, '-B', '-c', 'import sys; sys.stdin.read()'],
                                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                request = self.request(root, owner.pid)
                pids = root / 'child-pids.txt'
                runner = None
                handles = []
                try:
                    runner = subprocess.Popen([str(exe), 'job', str(request), str(pids)],
                                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    deadline = time.monotonic() + 10
                    while not pids.is_file() and runner.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.025)
                    children = pids.read_text(encoding='utf-8').split(',')
                    self.assertEqual(len(children), 2)
                    for pid in children:
                        handle = kernel.OpenProcess(0x00100001, False, int(pid))
                        self.assertTrue(handle, ctypes.get_last_error())
                        handles.append(handle)
                    if cause == 'marker':
                        request.with_name(request.name + '.cancel').touch()
                    else:
                        owner.stdin.close()
                        owner.wait(timeout=8)
                    stdout, stderr = runner.communicate(timeout=8)
                    self.assertEqual(runner.returncode, 0, stderr.decode(errors='replace'))
                    self.assertEqual(json.loads(stdout), {'error_reason': 'cancelled'})
                    for handle in handles:
                        self.assertEqual(kernel.WaitForSingleObject(handle, 3000), 0)
                finally:
                    if runner is not None and runner.poll() is None:
                        runner.kill()
                        runner.communicate(timeout=5)
                    for handle in handles:
                        if kernel.WaitForSingleObject(handle, 0) == 258:
                            kernel.TerminateProcess(handle, 1)
                        kernel.CloseHandle(handle)
                    if owner.poll() is None:
                        owner.kill()
                        owner.wait(timeout=5)
                    owner.stdin.close()


if __name__ == '__main__':
    unittest.main()
