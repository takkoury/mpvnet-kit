"""Named unittest groups with explicit prerequisites and skip accounting."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'
if str(TESTS) not in sys.path:
    sys.path.insert(0, str(TESTS))

from support.install_fixtures import (checked_fixture_root, load_release_files,
                                      package_directory, powershell_path, runtime_hashes)

PROFILES = {
    'core': (
        'test_context_menu.ContextMenu', 'test_danmaku.DanmakuTests',
        'test_package_build.PackageBuild', 'test_user_preferences_export.UserPreferencesExport',
        'test_test_support.TestSupport', 'test_test_runner.RunnerContract',
        'test_documentation.DocumentationLinks',
    ),
    'lua': (
        'test_capture_single_format.CaptureRouting', 'test_chapter_preview.ChapterPreview',
        'test_control_tooltips.ControlTooltips', 'test_enhancement_controls.EnhancementControls',
        'test_enhancement_controls.ModernzEnhancementFooter',
        'test_failure_feedback.PlaybackEndFeedback', 'test_failure_feedback.FailureFeedback',
        'test_failure_feedback.DanmakuFailureFeedback', 'test_modernz.ModernzInteractions',
        'test_playlist_controls.PlaylistControls', 'test_responsive_osc.ResponsiveOsc',
        'test_seekbar_markers.SeekbarMarkers', 'test_subtitle_controls.SubtitleControls',
        'test_user_shortcuts.UserShortcuts', 'test_user_settings.UserSettings', 'test_settings_display.SettingsDisplay',
    ),
    'helpers': (
        'test_capture_single_format.CaptureOutputs', 'test_failure_feedback.CaptureHelperReasons',
        'test_playlist_window.PlaylistWindow', 'test_shortcuts_window.ShortcutsWindow',
        'test_user_preferences.UserPreferences', 'test_settings_storage.SettingsStorage',
        'test_settings_window.SettingsWindow',
    ),
    'install': (
        'test_install_targets.InstallTargets', 'test_legacy_backup.LegacyBackup',
        'test_maintenance.Maintenance', 'test_user_settings_upgrade.UserSettingsUpgrade',
    ),
}
REQUIREMENTS = {
    'core': 'Python 标准库；Git（源码文档清单）',
    'lua': 'MPVNET_TEST_LUA51：已有的 Lua 5.1 共享库',
    'helpers': 'Windows PowerShell、Git；MPVNET_TEST_PLAYLIST_ARTIFACTS：仓外证据目录',
    'install': ('Windows PowerShell、Git 与固定旧发行历史；MPVNET_INSTALL_TARGET_ROOT、'
                'MPVNET_LEGACY_ROOT/PACKAGE、MPVNET_MAINTENANCE_ROOT/PACKAGE、'
                'MPVNET_USER_UPGRADE_ROOT/OLD_PACKAGE/NEW_PACKAGE'),
}
OPTIONAL_SKIPS = {
    'test_user_shortcuts.UserShortcuts.test_native_snapshot_matches_cached_upstream_getdefaults': 'MPVNET_NATIVE_INPUT_HELP',
    'test_capture_single_format.CaptureOutputs.test_real_encoders_save_only_selected_file_and_remove_intermediate': 'MPVNET_TEST_FFMPEG',
    'test_capture_single_format.CaptureOutputs.test_commit_and_clipboard_failure_leave_existing_files_untouched': 'MPVNET_TEST_FFMPEG',
    'test_playlist_window.PlaylistWindow.test_owned_window_visible_edges': 'MPVNET_TEST_PLAYLIST_WINDOWS',
}


def flatten(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from flatten(test)
        else:
            yield test


def inventory():
    """Every discovered test must belong to exactly one class in the registry."""
    loader = unittest.TestLoader()
    found = list(flatten(loader.discover(str(TESTS))))
    if loader.errors:
        raise RuntimeError('\n'.join(loader.errors))
    owners = [name for names in PROFILES.values() for name in names]
    if len(owners) != len(set(owners)):
        raise RuntimeError('测试类重复归组')
    actual = {test.__class__.__module__ + '.' + test.__class__.__name__ for test in found}
    if actual != set(owners):
        raise RuntimeError('测试类归组不一致；未归组=%s，失效登记=%s' %
                           (sorted(actual - set(owners)), sorted(set(owners) - actual)))
    ids = [test.id() for test in found]
    if len(ids) != len(set(ids)):
        raise RuntimeError('发现重复测试 ID')
    return found


def _required(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError('缺少必要条件：' + name)
    return value


def _optional_file(name):
    value = os.environ.get(name)
    if value and (not Path(value).is_absolute() or not Path(value).is_file()):
        raise RuntimeError(name + ' 必须指向已有文件的绝对路径')


def preflight(profiles):
    """Inspect all selected groups before any unittest fixture can be created."""
    if {'core', 'helpers', 'install'} & set(profiles) and not shutil.which('git'):
        raise RuntimeError('所选测试组需要 Git')
    if 'lua' in profiles:
        _required('MPVNET_TEST_LUA51')
        from lua_runtime import load_lua51
        try:
            load_lua51()  # Reject incompatible libraries before helper fixtures run.
        except (OSError, AttributeError) as error:
            raise RuntimeError('无法加载指定的 Lua 5.1 库：' + str(error)) from error
        _optional_file('MPVNET_NATIVE_INPUT_HELP')
    if {'helpers', 'install'} & set(profiles):
        powershell_path()
    helper_root = None
    if 'helpers' in profiles:
        if not shutil.which('powershell.exe'):
            raise RuntimeError('helpers 组需要 PATH 中可用的 powershell.exe')
        helper_root = _required('MPVNET_TEST_PLAYLIST_ARTIFACTS')
        _optional_file('MPVNET_TEST_FFMPEG')
    if 'install' not in profiles:
        if helper_root:
            checked_fixture_root(helper_root, ROOT, mode='unique')
        return
    packages = {name: package_directory(_required(name)) for name in (
        'MPVNET_LEGACY_PACKAGE', 'MPVNET_MAINTENANCE_PACKAGE',
        'MPVNET_USER_UPGRADE_OLD_PACKAGE', 'MPVNET_USER_UPGRADE_NEW_PACKAGE')}
    inputs = tuple(packages.values())
    roots = [checked_fixture_root(_required(name), ROOT, packages=inputs) for name in (
        'MPVNET_INSTALL_TARGET_ROOT', 'MPVNET_LEGACY_ROOT',
        'MPVNET_MAINTENANCE_ROOT', 'MPVNET_USER_UPGRADE_ROOT')]
    for i, root in enumerate(roots):
        if any(root == other or root in other.parents or other in root.parents for other in roots[i + 1:]):
            raise RuntimeError('各安装测试组必须使用独立的新目录')
    if helper_root:
        helper_root = checked_fixture_root(helper_root, ROOT, packages=inputs, mode='unique')
        if any(helper_root == root or root in helper_root.parents for root in roots):
            raise RuntimeError('helpers 证据目录不能位于安装测试目录内')
    for prefix in ('MPVNET_LEGACY', 'MPVNET_MAINTENANCE'):
        package = packages[prefix + '_PACKAGE']
        catalog = json.loads((package / 'tools/legacy-releases.json').read_text(encoding='utf-8-sig'))
        releases = catalog['releases']
        if prefix == 'MPVNET_MAINTENANCE':
            releases = [next(release for release in releases if release['version'] == '0.2.0')]
        repo = Path(os.environ.get('MPVNET_LEGACY_RELEASE_REPO', ROOT))
        for release in releases:
            load_release_files(repo, release)
    before = runtime_hashes(packages['MPVNET_USER_UPGRADE_OLD_PACKAGE'])
    after = runtime_hashes(packages['MPVNET_USER_UPGRADE_NEW_PACKAGE'])
    if not before or not set(before) < set(after) or 'mpvnet-user.json' in after:
        raise RuntimeError('用户设置回归需要保留旧运行文件并新增文件的新包')


def unexpected_skips(result):
    unexpected = []
    for test, reason in result.skipped:
        variable = OPTIONAL_SKIPS.get(test.id())
        enabled = (os.environ.get(variable) == '1' if variable == 'MPVNET_TEST_PLAYLIST_WINDOWS'
                   else bool(os.environ.get(variable))) if variable else False
        if not variable or enabled:
            unexpected.append((test.id(), reason))
    return unexpected


def run(profiles, tests, *, stream=None):
    classes = {name for group in profiles for name in PROFILES[group]}
    selected = [test for test in tests if test.__class__.__module__ + '.' + test.__class__.__name__ in classes]
    if not selected:
        raise RuntimeError('所选测试组为空')
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(unittest.TestSuite(selected))
    extra_skips = unexpected_skips(result)
    summary = {'profiles': list(profiles), 'run': result.testsRun, 'failures': len(result.failures),
               'errors': len(result.errors), 'skipped': len(result.skipped),
               'skipReasons': [{'test': test.id(), 'reason': reason} for test, reason in result.skipped],
               'unexpectedSkips': extra_skips}
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if result.wasSuccessful() and not extra_skips else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', action='append', choices=PROFILES, help='可重复指定测试组')
    parser.add_argument('--list', action='store_true', help='仅列出测试类与前置条件')
    args = parser.parse_args(argv)
    if not args.profile and not args.list:
        parser.print_help()
        return 0
    try:
        tests = inventory()
        profiles = list(dict.fromkeys(args.profile or PROFILES))
        if args.list:
            for name in profiles:
                print(name + '：' + REQUIREMENTS[name])
                for cls in PROFILES[name]:
                    print('  ' + cls)
            print('可选检查仅在对应环境变量显式配置后执行；结果不代表完整人工验收。')
            return 0
        preflight(profiles)
        return run(profiles, tests)
    except (RuntimeError, OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        print('测试未启动：' + str(error), file=sys.stderr)
        return 2
