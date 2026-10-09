# thumbfast provenance

Upstream: [po5/thumbfast](https://github.com/po5/thumbfast)
Pinned revision: `0f711de3138c9bd6718209d819ac54022c23ded2`.
The modified script is provided as source under [MPL-2.0](LICENSE); the original license notice is retained.

| Input | SHA256 |
| --- | --- |
| Original upstream thumbfast.lua | `a3d08e71eae8b892f6cd39f9593ea219768e709312d176bca883841b156448bf` |
| Distributed modified thumbfast.lua | `cf1a4899687b59fbb2cd6a9889b2a2044c21e7c727499cddf7295fe05f6b4d41` |

## Local modifications

2026-10-10: explicitly load the configuration path module; discover the Windows worker executable from a private override, component option, frontend path, a single query of the current process ID, or an existing executable beside the configuration directory. Related failures produce a diagnostic. Thumbnail generation and message handling retain the upstream implementation.

Network thumbnails are disabled by the distributed options. See the [customization guide](../../docs/customization.md) for local path overrides. The package manifest records distributed file hashes. The complete modified source accompanies this notice.
