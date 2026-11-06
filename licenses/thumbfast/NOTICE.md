# thumbfast provenance

Upstream: [po5/thumbfast](https://github.com/po5/thumbfast)
Pinned revision: `0f711de3138c9bd6718209d819ac54022c23ded2`.
The modified script is provided as source under [MPL-2.0](LICENSE); the original license notice is retained.

| Input | SHA256 |
| --- | --- |
| Original upstream thumbfast.lua | `a3d08e71eae8b892f6cd39f9593ea219768e709312d176bca883841b156448bf` |
| Distributed modified thumbfast.lua | `e45fead4fe32ed42d8cf0516405b52575cf969c698409fe561976e9baf40bb1e` |

## Local modifications

2026-11-06: delegate the existing startup OSD routing and four-second policy to the shared kit feedback client. Keep the compatibility host messages and all thumbnail worker behavior.

2026-11-06: use concise Chinese startup failure messages and the kit feedback coordinator when available, with native OSD fallback. Preserve backend discovery, retry branches and upstream terminal diagnostics; existing Windows frontend fallback messages use the same four-second error duration.

2026-10-10: explicitly load the configuration path module; discover the Windows worker executable from a private override, component option, frontend path, a single query of the current process ID, or an existing executable beside the configuration directory. Related failures produce a diagnostic. Thumbnail generation and message handling retain the upstream implementation.

Network thumbnails are disabled by the distributed options. See the [configuration guide](../../docs/configuration.md) for local path overrides. The package manifest records distributed file hashes. The complete modified source accompanies this notice.
