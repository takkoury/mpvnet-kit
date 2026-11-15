# Playback adapter: one fixed model, one GPU stream, no compilation in the player.
from pathlib import Path
import ctypes
import json
import os
import threading
import vapoursynth as vs

request = json.loads(Path(user_data).read_text(encoding="utf-8-sig"))
bundle = Path(request["bundle_root"])
engine = Path(request["engine_path"])
# Retain the directory cookies for the lifetime of this script/filter graph.
_dll_handles = [os.add_dll_directory(str(bundle / name)) for name in ("plugins/vsmlrt-cuda", "plugins")]
_libraries = [ctypes.WinDLL(str(bundle / "plugins/vsmlrt-cuda" / name), winmode=0x900)
              for name in ("nvinfer_10.dll", "nvinfer_plugin_10.dll")]
core = vs.core
core.max_cache_size = 256
core.std.LoadPlugin(str(bundle / "plugins/vstrt.dll"))
source = video_in
width, height = request["width"], request["height"]
if (source.width, source.height) != (width, height):
    raise ValueError("Video dimensions changed; retire the old preparation task")
if source.format is None or source.format.color_family != vs.YUV:
    raise ValueError("This enhancement requires a supported planar YUV input")
matrix = request["matrix"]
levels = request["levels"]
if matrix not in ("709", "470bg", "170m", "2020ncl") or levels not in ("limited", "full"):
    raise ValueError("Unsupported source color interpretation")
chroma = request["chroma"]
if chroma not in ("left", "center", "top_left", "top", "bottom_left", "bottom"):
    raise ValueError("Unsupported source chroma position")

def progressive(n, f):
    if f.props.get("_FieldBased", 0):
        raise ValueError("Interlaced video is outside this enhancement's supported scope")
    return f

source = core.std.ModifyFrame(source, source, progressive)
rgb = core.resize.Bicubic(source, format=vs.RGBS, matrix_in_s=matrix,
                          range_in_s=levels, range_s="full", chromaloc_in_s=chroma)
pw, ph = request["padded_width"], request["padded_height"]
if (pw, ph) != (width, height):
    # A source rectangle with 1:1 sampling extends beyond the right/bottom edge;
    # zimg repeats the border pixels. This avoids a black seam or source stretching.
    rgb = core.resize.Point(rgb, width=pw, height=ph, src_width=pw, src_height=ph)
output = core.trt.Model(rgb, engine_path=str(engine), device_id=request["device_id"],
                        num_streams=1, use_cuda_graph=True, verbosity=1)
if (pw, ph) != (width, height):
    output = core.std.CropRel(output, right=(pw - width) * 2, bottom=(ph - height) * 2)
output = core.std.Expr(output, expr=["x 0 max 1 min"])
output = core.resize.Bicubic(output, format=source.format.id, matrix_s=matrix,
                             range_in_s="full", range_s=levels, chromaloc_s=chroma)
# Preserve mpv's opaque image reference, SAR, frame duration and color metadata.
output = core.std.CopyFrameProps(output, source)
_ready_lock = threading.Lock()
_ready_sent = Path(user_data + '.ready').is_file()

def signal_first_frame(n, f):
    global _ready_sent
    # mpv can ask for a zero-duration dummy during graph construction. Only a
    # computed output paired with a real source frame is evidence for activation.
    if not _ready_sent and f[1].props.get('_DurationNum', 0) > 0:
        with _ready_lock:
            if not _ready_sent:
                ready = Path(user_data + '.ready')
                partial = Path(user_data + '.ready.part')
                partial.write_text(json.dumps({'activation_id': request['activation_id']}), encoding='utf-8')
                partial.replace(ready)
                _ready_sent = True
    return f[0]

output = core.std.ModifyFrame(output, [output, source], signal_first_frame)
output.set_output()
