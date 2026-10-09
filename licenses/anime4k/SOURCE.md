# Anime4K source provenance

Upstream: https://github.com/bloc97/Anime4K
Release: v4.0.1 (GLSL stable)
Commit: 4029bf701ecaa15f163cdc49cffe5501c1acf410
Instructions: https://github.com/bloc97/Anime4K/blob/4029bf701ecaa15f163cdc49cffe5501c1acf410/GLSL_Instructions.md
Licenses: six shaders carry MIT notices; the two AutoDownscalePre shaders carry Unlicense/public-domain dedication notices. The upstream project MIT [LICENSE](LICENSE) and the AutoDownscale [Unlicense text](UNLICENSE) are retained; each file header remains authoritative for that file.

Only eight unmodified GLSL text files are vendored; no upstream input.conf or mpv.conf is installed.
ANIME_LIGHT follows official Mode B (Fast); ANIME_STRONG follows official Mode A (HQ).
The labels describe two selected restoration chains, not universal suitability or GPU performance.
mpv supports custom GLSL hooks with GPU renderers; gpu-next/D3D11 compatibility is subject to actual local compilation and active-pass verification.
Reference: https://mpv.io/manual/stable/#options-glsl-shader

| Local filename | Upstream path at fixed commit | SHA-256 |
| --- | --- | --- |
| Anime4K_Clamp_Highlights.glsl | glsl/Restore/Anime4K_Clamp_Highlights.glsl | a2a9bf7fbc1d75d09660ca2e701e4d7fb0cf5457b94da47e1825032fa2b3671a |
| Anime4K_Restore_CNN_Soft_M.glsl | glsl/Restore/Anime4K_Restore_CNN_Soft_M.glsl | a78a2c76898e08e09e442a9628c64208c26e8e15789649b8755223f009794c02 |
| Anime4K_Restore_CNN_VL.glsl | glsl/Restore/Anime4K_Restore_CNN_VL.glsl | 35036722733305cd4d4e57660b883bbe2569ba2914033c254327107d7b77e35e |
| Anime4K_Upscale_CNN_x2_M.glsl | glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl | 716e02098a68f0d648761f2b96b4dd139e1cb09b174bb369fca3aa34328fff7e |
| Anime4K_Upscale_CNN_x2_S.glsl | glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl | 4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4 |
| Anime4K_Upscale_CNN_x2_VL.glsl | glsl/Upscale/Anime4K_Upscale_CNN_x2_VL.glsl | 5638fe31c37c151a3443fea3451a3ef91af073f4dbb9615f6c0d1e29db11493d |
| Anime4K_AutoDownscalePre_x2.glsl | glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl | 8c58291740146bd766a4d73f132775a797fe80f7d07919b5d767e27a5dc85656 |
| Anime4K_AutoDownscalePre_x4.glsl | glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl | 5af62d8cd844916dc1126613e13bad3beab195787f93a71200b47c6ec78f2e41 |

Upstream whitespace is retained byte-for-byte, including trailing spaces in Clamp_Highlights. Project whitespace checks cover owned code/docs; these pinned vendor shader bytes are verified by SHA-256 instead of reformatted.
