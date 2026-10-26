"""User preferences cannot accidentally become managed distribution files."""
import json
from pathlib import Path
import tempfile
import unittest
import runpy

ROOT = Path(__file__).resolve().parents[1]
EXPORT = runpy.run_path(str(ROOT / 'dev-tools/build-package.py'))['export']

class UserPreferencesExport(unittest.TestCase):
    def test_user_state_is_absent_from_distribution(self):
        mapping = json.loads((ROOT / 'dev-tools/package-map.json').read_text(encoding='utf-8'))
        self.assertFalse(any(Path(e['source']).name.lower() == 'mpvnet-user.json' or Path(e['destination']).name.lower() == 'mpvnet-user.json' for e in mapping['files']))
        self.assertIn('/config/mpvnet-user.json', (ROOT / '.gitignore').read_text(encoding='utf-8'))
        self.assertIn('mpvnet-user.json', (ROOT / '.gitignore').read_text(encoding='utf-8'))
    def test_export_rejects_user_file_even_if_added_to_allowlist(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / 'source'; source.mkdir()
            for src,dst in [('mpvnet-user.json','config/data.json'),('data.json','config/mpvnet-user.json')]:
                (source / src).write_text('{"schema":1,"shortcuts":{}}', encoding='utf-8')
                spec = root / 'map.json'
                spec.write_text(json.dumps({'schema':1,'version':'test','files':[{'source':src,'destination':dst,'component':'author','origin':'test'}]}),encoding='utf-8')
                with self.assertRaisesRegex(ValueError, 'user preferences must not be exported'):
                    EXPORT(source,root / 'output',spec,True)
                self.assertFalse((root / 'output').exists())
