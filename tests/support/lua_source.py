"""Explicit extraction and option types for real-source Lua test fixtures."""
import json
from pathlib import Path


def fragment(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


def feedback_module():
    """Return a Lua expression executing the complete production feedback module."""
    path = Path(__file__).resolve().parents[2] / 'config/script-modules/feedback.lua'
    return '(function()\n' + path.read_text(encoding='utf-8') + '\nend)()'


def upscale_catalog_fixture():
    """Use the production catalog's presentation fields in mp.utils JSON doubles."""
    path = Path(__file__).resolve().parents[2] / 'config/upscale/models.json'
    catalog = json.loads(path.read_text(encoding='utf-8'))
    models = ',\n'.join(
        f"{key}={{label={json.dumps(value['label'], ensure_ascii=False)},"
        f"description={json.dumps(value['description'], ensure_ascii=False)}}}"
        for key, value in catalog['models'].items()
    )
    return f"local upscale_catalog = {{schema={catalog['schema']},models={{\n{models}\n}}}}\n"


def _options(path):
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        if line.strip() and not line.lstrip().startswith('#'):
            yield line.split('=', 1)


def string_configuration(path):
    """Keep every value a Lua string, as the older interaction fixtures do."""
    return '\n'.join('user_opts[%s] = %s' % (json.dumps(key), json.dumps(value, ensure_ascii=False))
                     for key, value in _options(path))


def typed_configuration(path):
    """Use booleans/numbers where present, matching layout/tooltip fixtures."""
    lines = []
    for key, value in _options(path):
        if value in ('yes', 'no'):
            literal = 'true' if value == 'yes' else 'false'
        else:
            try:
                float(value)
                literal = value
            except ValueError:
                literal = json.dumps(value, ensure_ascii=False)
        lines.append('user_opts[%s] = %s' % (json.dumps(key), literal))
    return '\n'.join(lines)
