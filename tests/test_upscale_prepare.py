"""Model-source failures and existing engine identity, without ONNX or GPU imports."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('upscale_prepare', ROOT / 'config/upscale/prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class UpscalePrepare(unittest.TestCase):
    def test_animation_cache_keys_match_pre_span_contract(self):
        # Captured from the 9574582 identity expression, with public fixture GPU
        # identifiers. Catalogue additions must not retire either existing key.
        expected = {'CUGAN': '16d326d40bd44b20e97bf39c0bb1c69dc213283ddc5e35580e037b33466e1980',
                    'ESRGAN': '9fcff69cfbbfd6e69ca77d87b343789fcfbc55bd9984339a6614907c5f9522a0'}
        models = json.loads((ROOT / 'config/upscale/models.json').read_text(encoding='utf-8'))['models']
        request = dict(bundle_id='trt-10.16-v1', manifest_sha256='1' * 64,
                       gpu_uuid='GPU-fixture', driver='fixture-driver')
        for name, key in expected.items():
            model = models[name]
            multiple = model['pad_multiple']
            padded = (854 + multiple - 1) // multiple * multiple
            identity = prepare.cache_identity(name, model, model['sha256'], request, 854, 480, padded, 480)
            actual = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            self.assertEqual(actual, key, name)

    def test_packaged_model_does_not_depend_on_animation_model_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'config'
            models = config / 'upscale/models'
            models.mkdir(parents=True)
            shutil.copyfile(ROOT / 'config/upscale/models.json', config / 'upscale/models.json')
            asset = 'nomosuni-span-multijpg-ldl-2x-v1.onnx'
            source = models / asset
            bundle = Path(temporary) / 'bundle'
            with self.assertRaises(prepare.ModelFailure) as missing:
                prepare.model_source(config, bundle, 'SPAN')
            self.assertEqual(missing.exception.reason, 'model_missing')
            shutil.copyfile(ROOT / 'config/upscale/models' / asset, source)
            definition, actual, digest = prepare.model_source(config, bundle, 'SPAN')
            self.assertEqual(actual, source)
            self.assertEqual(digest, definition['sha256'])
            data = bytearray(source.read_bytes())
            data[-1] ^= 1
            source.write_bytes(data)
            with self.assertRaises(prepare.ModelFailure) as changed:
                prepare.model_source(config, bundle, 'SPAN')
            self.assertEqual(changed.exception.reason, 'model_integrity')

