"""Guard native capability retention and the existing physical-key contract.

The fixture records the pre-change host menu, independently of the new layout.
Host WPF rendering/dynamic population requires the separate isolated check.
"""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASELINE = json.loads((ROOT / 'tests/fixtures/native-menu.json').read_text(encoding='utf-8'))


def entries():
    for line in (ROOT / 'config/input.conf').read_text(encoding='utf-8-sig').splitlines():
        body, _, comment = line.partition('#')
        if not body.strip():
            continue
        key, command = body.strip().split(None, 1)
        yield key, command, comment.removeprefix('menu:').strip() if comment.startswith('menu:') else None


class ContextMenu(unittest.TestCase):
    def test_native_capabilities_retained(self):
        commands = {command for _, command, path in entries() if path}
        for original in BASELINE['native_commands']:
            with self.subTest(command=original):
                if original in BASELINE['removed']:
                    self.assertNotIn(original, commands)
                else:
                    self.assertIn(BASELINE['replacements'].get(original, original), commands)
        self.assertIn('quit-watch-later', commands)

    def test_physical_keys_unchanged(self):
        keys = {key: command for key, command, _ in entries() if key != '_'}
        expected = BASELINE['baseline_keys'] | {'MBTN_RIGHT': 'script-message-to mpvnet show-menu'}
        self.assertEqual(expected, keys)
        self.assertTrue(all(key == '_' for key, _, path in entries() if path))
        self.assertEqual([command for key, command, _ in entries() if key == '_'][-1], 'ignore')

    def test_chinese_roots_and_unambiguous_paths(self):
        paths = [path for _, _, path in entries() if path]
        roots = list(dict.fromkeys(path.split(' > ')[0] for path in paths))
        self.assertEqual(roots, ['文件', '播放', '字幕与弹幕', '音频', '画面', '截图与片段', '窗口与界面', '工具与设置'])
        leaves = [path for path in paths if path.split(' > ')[-1] != '-']
        self.assertEqual(len(leaves), len(set(leaves)))
        self.assertTrue(all(2 <= len(path.split(' > ')) <= 3 for path in paths))
        self.assertFalse(any(other.startswith(path + ' > ') for path in leaves for other in leaves))

    def test_native_dynamic_labels_and_locale(self):
        dynamic = [path.split(' > ')[-1] for _, command, path in entries()
                   if path and command == 'ignore' and not path.endswith(' > -')]
        self.assertCountEqual(BASELINE['dynamic_labels'], dynamic)
        conf = (ROOT / 'config/mpvnet.conf').read_text(encoding='utf-8-sig').splitlines()
        self.assertIn('language=chinese-china', conf)

    def test_fresh_host_migration_cannot_overwrite_language_config(self):
        # App.ApplyInputDefaultBindingsFix in the pinned 96afc621 host searches
        # these two literal forms, then incorrectly writes to App.ConfPath.
        conf = (ROOT / 'config/mpv.conf').read_text(encoding='utf-8-sig')
        for trigger in ('input-default-bindings=no', 'input-default-bindings = no'):
            self.assertNotIn(trigger, conf)
        options = dict(line.split('#', 1)[0].split('=', 1) for line in conf.splitlines()
                       if line.strip() and not line.lstrip().startswith('#') and '=' in line)
        self.assertEqual(options['input-default-bindings'].strip(), 'no')

    def test_kit_actions_use_current_backends(self):
        menu = {path: command for _, command, path in entries() if path}
        expected = {
            '播放 > 播放／暂停（Space）': 'script-binding playback_feedback/toggle-pause',
            '窗口与界面 > 切换控制栏显示方式': 'script-binding playback_feedback/osc-visibility',
            '窗口与界面 > 显示／隐藏播放列表侧窗': 'script-binding playlist_controls/toggle',
            '字幕与弹幕 > 恢复字幕位置与字号': 'script-binding subtitle_controls/reset-adjustment',
            '字幕与弹幕 > 选择普通字幕…': 'script-binding subtitle_controls/select',
            '截图与片段 > 保存源画面 PNG': 'script-binding capture_controls/screenshot',
            '截图与片段 > 复制最近导出片段': 'script-binding capture_controls/copy-latest',
        }
        for path, command in expected.items():
            self.assertEqual(menu[path], command)
        self.assertNotIn('script-binding playback_feedback/space', menu.values())
        self.assertNotIn('script-binding osc/visibility', menu.values())
        for format in ('webp', 'gif', 'mp4'):
            self.assertEqual(menu['截图与片段 > 导出格式 > ' + {'webp':'WebP','gif':'GIF','mp4':'MP4'}[format]],
                             'script-message-to capture_controls set-default-format ' + format)
            self.assertNotIn('script-binding capture_controls/copy-' + format, menu.values())


if __name__ == '__main__':
    unittest.main()
