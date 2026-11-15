#!/usr/bin/env python3
"""Reproduce the packaged SPAN ONNX on CPU; never download or install dependencies."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys

WEIGHTS_SHA256 = '59d96e844503a93303cbd780ba083d68049745b5307cb90bb3c05aad8180bb49'
ONNX_SHA256 = 'd82255d20b2e8e73d2ddb350820e188540b94fa3faeade494fc47c59ef49f266'


def export(checkpoint, output):
    import numpy as np
    import onnx
    from onnx.reference import ReferenceEvaluator
    import spandrel
    from spandrel import ModelLoader, ImageModelDescriptor, canonicalize_state_dict
    import torch

    versions = {'torch': torch.__version__, 'spandrel': spandrel.__version__,
                'onnx': onnx.__version__, 'numpy': np.__version__}
    required = {'torch': '2.9.1+cpu', 'spandrel': '0.4.2', 'onnx': '1.18.0', 'numpy': '2.2.6'}
    if versions != required:
        raise ValueError('Use the documented CPU export versions: ' + repr(required))
    if hashlib.sha256(checkpoint.read_bytes()).hexdigest() != WEIGHTS_SHA256:
        raise ValueError('Checkpoint differs from the pinned author release')
    torch.set_num_threads(4)
    torch.set_num_interop_threads(2)
    state = canonicalize_state_dict(torch.load(checkpoint, map_location='cpu', weights_only=True))
    descriptor = ModelLoader(device='cpu').load_from_state_dict(state).eval()
    if (not isinstance(descriptor, ImageModelDescriptor) or str(descriptor.architecture.id) != 'SPAN'
            or descriptor.scale != 2 or descriptor.input_channels != 3 or descriptor.output_channels != 3
            or not descriptor.model.is_norm or 'no_norm' in state):
        raise ValueError('Unexpected model identity or normalization')
    sample = np.random.default_rng(1611).random((1, 3, 16, 16), dtype=np.float32)
    x = torch.from_numpy(sample)
    with torch.inference_mode():
        reference = descriptor(x).clone()
    folded = copy.deepcopy(descriptor.model).eval()
    replacements = []

    def freeze(module, prefix=''):
        # The original evaluation call above materializes these inference
        # convolutions from all training branches. Preserve their exact values.
        for name, child in list(module.named_children()):
            if type(child).__name__ == 'Conv3XC':
                replacement = copy.deepcopy(child.eval_conv)
                if child.has_relu:
                    replacement = torch.nn.Sequential(replacement, torch.nn.LeakyReLU(negative_slope=.05))
                setattr(module, name, replacement)
                replacements.append(prefix + name)
            else:
                freeze(child, prefix + name + '.')

    freeze(folded)
    if len(replacements) != 20:
        raise ValueError('Unexpected inference graph')

    class Bounded(torch.nn.Module):
        def __init__(self, module):
            super().__init__()
            self.network = module

        def forward(self, x):
            return self.network(x).clamp(0.0, 1.0)

    model = Bounded(folded).eval()
    with torch.inference_mode():
        folded_error = float((model(x) - reference).abs().max())
        if folded_error >= 1e-6:
            raise ValueError('Inference reparameterization changed the output')
        torch.onnx.export(model, (x,), str(output / 'model.onnx'), dynamo=False, opset_version=17,
                          input_names=['input'], output_names=['output'],
                          dynamic_axes={'input': {2: 'height', 3: 'width'},
                                        'output': {2: 'out_height', 3: 'out_width'}})
    graph = onnx.load(str(output / 'model.onnx'))
    onnx.checker.check_model(graph)
    actual = ReferenceEvaluator(graph).run(None, {'input': sample})[0]
    difference = np.abs(actual - reference.numpy())
    if actual.shape != (1, 3, 32, 32) or not np.isfinite(actual).all() or difference.max() >= 1e-4:
        raise ValueError('CPU export equivalence check failed')
    digest = hashlib.sha256((output / 'model.onnx').read_bytes()).hexdigest()
    report = {'versions': versions, 'weights_sha256': WEIGHTS_SHA256, 'onnx_sha256': digest,
              'inference_modules': replacements, 'normalization_preserved': True,
              'folded_max_abs': folded_error, 'onnx_max_abs': float(difference.max()),
              'matches_packaged_asset': digest == ONNX_SHA256}
    (output / 'export.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if digest != ONNX_SHA256:
        raise ValueError('Export differs from the packaged asset; inspect the output before updating any pin')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New external evidence directory')
    parser.add_argument('--dependency-dir', type=Path, action='append', default=[],
                        help='Existing isolated CPU packages; repeat to combine existing directories')
    args = parser.parse_args()
    output = args.output.absolute()
    repository = Path(__file__).resolve().parents[1]
    if output.exists() or output.resolve().is_relative_to(repository):
        parser.error('Output must be a new directory outside the source tree')
    if any(p.is_symlink() or p.is_junction() for p in (output, *output.parents)):
        parser.error('Output must not use links or junctions')
    sys.path[:0] = [str(p.resolve(strict=True)) for p in args.dependency_dir]
    output.mkdir(parents=True)
    export(args.checkpoint.resolve(strict=True), output)


if __name__ == '__main__':
    main()
