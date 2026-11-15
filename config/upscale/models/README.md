# NomosUni SPAN 写实模型

`nomosuni-span-multijpg-ldl-2x-v1.onnx`是mpvnet-kit维护的ONNX转换文件，来自Philip Hofmann的 **2xNomosUni_span_multijpg_ldl** 模型，采用[CC BY 4.0](CC-BY-4.0.txt)许可。本项目和此转换不代表原作者背书；模型不属于本项目MIT许可范围。

- 作者发行：[2xNomosUni_span_multijpg_ldl](https://github.com/Phhofm/models/releases/tag/2xNomosUni_span_multijpg_ldl)。作者说明日期2024-01-13；采用2024-09-11上传的GitHub PTH资产，不是旧Drive文件或safetensors文件。
- 原权重：`2xNomosUni_span_multijpg_ldl.pth`，8,960,986 B，SHA256 `59d96e844503a93303cbd780ba083d68049745b5307cb90bb3c05aad8180bb49`。
- 本转换：1,658,164 B，SHA256 `d82255d20b2e8e73d2ddb350820e188540b94fa3faeade494fc47c59ef49f266`；FP32、ONNX opset17、动态高宽、RGB输入输出、原生2倍。
- 转换日期2026-11-16。使用PyTorch2.9.1+cpu、Spandrel0.4.2、ONNX1.18.0、NumPy2.2.6；Spandrel按其原加载逻辑保留归一化，20处Conv3XC按已计算的eval卷积固化，保留0–1输出限幅。没有训练、混合其他权重或更改恢复强度。
- 固化前后小尺寸CPU输出最大差为0，ONNX与原加载器最大绝对差约4.18×10⁻⁶；这用于核对转换，不代表所有片源的恢复准确率。播放准备时再根据当前设备和尺寸生成FP16内部／FP32输入输出的本机引擎。

模型描述及校验值集中在[模型定义](../models.json)。正常使用不需要导出工具。导出工具仅用于源码维护，方法见源码仓库的CONTRIBUTING.md。

模型按CC BY 4.0条款以现状提供，不作效果保证。完整许可保留于[CC-BY-4.0.txt](CC-BY-4.0.txt)，规范链接为<https://creativecommons.org/licenses/by/4.0/>。
