"""Build one device/shape-specific engine. Invoked only by the owned preparation job."""
from pathlib import Path
import hashlib
import json
import msvcrt
import os
import subprocess
import sys
import time

MODELS = {"CUGAN": "cugan.onnx", "ESRGAN": "esrgan.onnx"}
RECIPE = 1


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def emit(phase, **data):
    print(json.dumps(dict(phase=phase, **data), ensure_ascii=True), flush=True)


def layout(bundle):
    """Keep handles alive: Python closes an AddDllDirectory cookie when collected."""
    folders = [bundle / "plugins/vsmlrt-cuda", bundle / "plugins",
               bundle / "runtime", bundle / "runtime/Lib/site-packages/vapoursynth"]
    handles = [os.add_dll_directory(str(p)) for p in folders]
    return handles


def check_engine(bundle, engine, width, height, device):
    import ctypes
    libraries = [ctypes.WinDLL(str(bundle / "plugins/vsmlrt-cuda" / name), winmode=0x900)
                 for name in ("nvinfer_10.dll", "nvinfer_plugin_10.dll")]
    import vapoursynth as vs
    core = vs.core
    core.max_cache_size = 64
    core.std.LoadPlugin(str(bundle / "plugins/vstrt.dll"))
    sample = core.std.BlankClip(width=width, height=height, format=vs.RGBS,
                               length=1, fpsnum=1, fpsden=1, keep=True)
    output = core.trt.Model(sample, engine_path=str(engine), device_id=device,
                            num_streams=1, use_cuda_graph=True, verbosity=1)
    frame = output.get_frame(0)
    if (frame.width, frame.height) != (width * 2, height * 2):
        raise ValueError("engine output dimensions do not match the recipe")
    import numpy as np
    if not all(np.isfinite(np.asarray(frame[p])).all() for p in range(3)):
        raise ValueError("engine produced non-finite values")


def main(request_path):
    request = json.loads(Path(request_path).read_text(encoding="utf-8-sig"))
    model_id = request["model"]
    if model_id not in MODELS:
        raise ValueError("unknown model")
    width, height = int(request["width"]), int(request["height"])
    if not (16 <= width <= 854 and 16 <= height <= 480):
        raise ValueError("unsupported input size")
    # CUGAN's encoder/decoder uses two spatial reductions. Replicate the edge in
    # the video adapter, then crop the 2x output; never stretch the source image.
    padded_w = (width + 3) // 4 * 4 if model_id == "CUGAN" else width
    padded_h = (height + 3) // 4 * 4 if model_id == "CUGAN" else height
    bundle = Path(request["bundle_root"]).resolve()
    cache = Path(request["cache_root"]).resolve()
    cache.mkdir(parents=True, exist_ok=True)
    source = bundle / "models" / MODELS[model_id]
    identity = dict(recipe=RECIPE, model=model_id, model_sha256=digest(source),
                    width=width, height=height, padded_width=padded_w, padded_height=padded_h,
                    bundle_id=request["bundle_id"], manifest_sha256=request["manifest_sha256"],
                    gpu_uuid=request["gpu_uuid"], driver=request["driver"],
                    precision="fp16-fp32-io", streams=1, cuda_graph=True,
                    workspace_mib=1024, builder_optimization=3, aux_streams=0)
    key = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    final = cache / key
    def cached():
        try:
            record = json.loads((final / "engine.json").read_text(encoding="utf-8"))
            engine = final / "model.engine"
            return record["identity"] == identity and record["engine_sha256"] == digest(engine)
        except (OSError, ValueError, KeyError):
            return False
    if cached():
        emit("ready", ok=True, cache_hit=True, cache_key=key, engine_path=str(final / "model.engine"),
             padded_width=padded_w, padded_height=padded_h)
        return
    lock = (cache / (key + ".lock")).open("a+b")
    if lock.tell() == 0:
        lock.write(b"0"); lock.flush()
    lock.seek(0)
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        emit("failed", ok=False, error_reason="cache_busy")
        return
    # The helper creates and owns this staging root. Its cancellation cleanup
    # cannot touch previously committed engines or another window's work.
    stage = Path(request["staging_root"]).resolve() / "engine"
    try:
        if cached():
            emit("ready", ok=True, cache_hit=True, cache_key=key, engine_path=str(final / "model.engine"),
                 padded_width=padded_w, padded_height=padded_h)
            return
        # Existing modified caches are preserved for diagnosis, not silently used.
        if final.exists():
            emit("failed", ok=False, error_reason="cache_invalid", cache_key=key)
            return
        stage.mkdir()
        started = time.monotonic()
        emit("converting", cache_key=key)
        import onnx
        from onnxconverter_common.float16 import convert_float_to_float16
        graph = onnx.load(str(source))
        for dim, value in zip(graph.graph.input[0].type.tensor_type.shape.dim,
                              [1, 3, padded_h, padded_w]):
            dim.ClearField("dim_param")
            dim.dim_value = value
        del graph.graph.value_info[:]
        for dim in graph.graph.output[0].type.tensor_type.shape.dim:
            dim.ClearField("dim_value"); dim.ClearField("dim_param")
        graph = onnx.shape_inference.infer_shapes(graph)
        graph = convert_float_to_float16(graph, keep_io_types=True)
        converted = stage / "model.onnx"
        onnx.save(graph, str(converted))
        onnx.checker.check_model(str(converted))
        engine = stage / "model.engine"
        args = [str(bundle / "plugins/vsmlrt-cuda/trtexec.exe"), "--onnx=" + str(converted),
                "--saveEngine=" + str(engine), "--stronglyTyped", "--noTF32",
                "--memPoolSize=workspace:1024", "--builderOptimizationLevel=3",
                "--maxAuxStreams=0", "--device=" + str(int(request["device_id"])),
                "--skipInference", "--timingCacheFile=" + str(stage / "timing.cache")]
        # The containing Windows Job owns this child too. Cancelling the helper
        # terminates actual compilation, including descendants, without taskkill.
        emit("compiling", cache_key=key)
        with (stage / "build.log").open("wb") as log:
            result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT,
                                    cwd=bundle / "plugins/vsmlrt-cuda", creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode != 0 or not engine.is_file():
            emit("failed", ok=False, error_reason="compile_failed", cache_key=key)
            return
        emit("checking", cache_key=key)
        handles = layout(bundle)
        check_engine(bundle, engine, padded_w, padded_h, int(request["device_id"]))
        record = dict(schema=1, identity=identity, engine_sha256=digest(engine),
                      converted_sha256=digest(converted), seconds=time.monotonic() - started)
        (stage / "engine.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        # A same-volume rename publishes the complete cache, including its receipt.
        stage.rename(final)
        emit("ready", ok=True, cache_hit=False, cache_key=key, engine_path=str(final / "model.engine"),
             padded_width=padded_w, padded_height=padded_h, seconds=record["seconds"])
    finally:
        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
        lock.close()


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except Exception as error:
        # The helper maps stable reasons to user text; detailed failures stay local.
        emit("failed", ok=False, error_reason="prepare_failed", detail=type(error).__name__ + ": " + str(error))
        sys.exit(1)
