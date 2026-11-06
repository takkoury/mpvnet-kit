"""Exercise the real Windows launcher with only a synthetic installer script."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from support.install_fixtures import checked_fixture_root

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Requires Windows cmd and Windows PowerShell')
class InstallLauncher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cmd = Path(os.environ['SystemRoot']) / 'System32/cmd.exe'
        cls.temp_root = checked_fixture_root(tempfile.gettempdir(), ROOT, mode='unique')

    def run_cmd(self, command, cwd, *, env=None):
        return subprocess.run(
            [self.cmd, '/d', '/c', command], cwd=cwd, env=env, input=b'x\r\n',
            capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW, timeout=30,
        )

    def check_launcher(self, installer_exit, expected_exit, message=''):
        with tempfile.TemporaryDirectory(prefix='mpvnet-install-launcher-', dir=self.temp_root) as temp:
            fixture = Path(temp)
            package = fixture / '完整 安装包'
            package.mkdir()
            launcher = package / 'Install.cmd'
            launcher.write_bytes((ROOT / 'Install.cmd').read_bytes())
            expected_output = b''
            if installer_exit is not None:
                installer = package / 'tools/installer.ps1'
                installer.parent.mkdir()
                installer.write_text(
                    "[Console]::WriteLine('fixture-installer-called')\n"
                    f'exit {installer_exit}\n', encoding='ascii',
                )
                expected_output = b'fixture-installer-called\r\n'
            if message:
                expected_output += (message + '\r\n').encode('utf-8')
                (fixture / 'wait.cmd').write_text('@echo off\nchcp %1 >nul\npause\n', encoding='ascii')
            driver = fixture / 'check.cmd'
            driver.write_text(
                '@echo off\n'
                'chcp %1 >nul || exit /b 99\n'
                'chcp\n'
                'echo fixture-start\n'
                'call "%MPVNET_TEST_LAUNCHER%"\n'
                'set "fixture_exit=%errorlevel%"\n'
                'echo fixture-end\n'
                'chcp\n'
                'exit /b %fixture_exit%\n',
                encoding='ascii',
            )
            env = dict(os.environ, MPVNET_TEST_LAUNCHER=str(launcher))
            for code_page in (437, 936, 65001):
                with self.subTest(code_page=code_page):
                    result = self.run_cmd(f'check.cmd {code_page}', fixture, env=env)
                    self.assertEqual(result.returncode, expected_exit, (result.stdout, result.stderr))
                    self.assertEqual(result.stderr, b'')
                    before, start, transcript = result.stdout.partition(b'fixture-start\r\n')
                    output, end, after = transcript.partition(b'fixture-end\r\n')
                    self.assertTrue(start and end, result.stdout)
                    self.assertTrue(before.rstrip().endswith(str(code_page).encode('ascii')), before)
                    self.assertEqual(after, before)
                    expected = expected_output
                    if message:
                        # The native pause prompt uses the caller's locale and code page.
                        pause = self.run_cmd(f'wait.cmd {code_page}', fixture)
                        self.assertEqual((pause.returncode, pause.stderr), (0, b''))
                        self.assertTrue(pause.stdout)
                        expected += pause.stdout
                    self.assertEqual(output, expected)

    def test_missing_installer_explains_how_to_retry(self):
        self.check_launcher(None, 1, '找不到安装程序。请解压完整的安装包，然后重试。')

    def test_failed_installer_explains_how_to_retry(self):
        self.check_launcher(1, 1, '安装程序未能启动或运行出错。请将完整安装包解压到可读取的文件夹后重试。')

    def test_successful_installer_returns_without_a_pause(self):
        self.check_launcher(0, 0)
