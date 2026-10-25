# Runtime sources and distribution boundaries

The source repository and the locally assembled runtime are different artifacts.
The repository's [Apache-2.0 license](../../LICENSE) does not relicense Linux,
Alpine packages or the separately downloaded Claude Code executable. The current
App builder packages the host executable; runtime images and the vendor disk are
selected separately. No public release of those third-party binaries is implied
by a successful local build.

## Fixed inputs

| Input | Version and source | Verification |
| --- | --- | --- |
| Alpine base | [3.24.3 aarch64 minirootfs](https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.3-aarch64.tar.gz) | SHA-256 `4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50` |
| Alpine kernel and modules | [3.24.3 aarch64 netboot](https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-netboot-3.24.3-aarch64.tar.gz), Linux `6.18.58-0-virt` | Archive SHA-256 `0ac085f19648562d33deb8bfdc339d747e40f456a49a43385d468ea46a888147`; decoded kernel `256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e` |
| Runtime packages | 44 aarch64 APKs in [dependencies.lock.json](../../Tools/AgentRuntime/dependencies.lock.json) | Each entry fixes version, URL, bytes, SHA-256, license expression and Alpine build-recipe commit |
| Business shell | Bash `5.3.9-r1`, one additional APK in [business-dependencies.lock.json](../../Tools/AgentRuntime/business-dependencies.lock.json) | SHA-256 `95f4f976bdf2f4ca18ff41c32916eb6d7b12a0dae12504d55d04427460d6542f`; 542,084 bytes; `GPL-3.0-or-later`; pinned Alpine recipe and package data digest recorded |
| Host image reader | [PySquashfsImage 0.9.0](https://pypi.org/project/PySquashfsImage/0.9.0/), build-time wheel only | SHA-256 `a8ea154bf946f985c65fab7d8c08dc73da7ad47a0aebf0d13ae50ae56e369f90`; checked before import |
| Claude Code | [2.1.309 linux-arm64-musl](https://downloads.claude.ai/claude-code-releases/2.1.309/linux-arm64-musl/claude) | 285,493,120 bytes; SHA-256 `028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332` |

The Claude source URL and upstream manifest observations are retained in
[artifact-manifest.json](../../Tools/AgentProtocolProbe/artifact-manifest.json).
The fixed padded read-only disk is 285,493,248 bytes, SHA-256
`c4e512ea944c420c80285b4c4bd817098d9845ac6aa6e423bbbb58b8d3a9bf43`.
The padding is zero bytes to the next sector; it is not a modified executable.
Vendor code is never run on the macOS build host.

Reuse matching existing inputs. The [package fetcher](../../Tools/AgentRuntime/fetch.py)
accepts only the lock's fixed Alpine HTTPS URLs and verifies existing files before
reuse. The [base builder](../../Tools/GuestFixture/build.py) verifies the three
base-input digests, then reads selected archive entries without extracting them
to the host. Its Go probe build requires Go 1.26.5 and disables module downloads.
The [vendor copier](../../Tools/AgentRuntime/vendor_data.py) requires an owned,
read-only regular input and creates a new destination. The [business profile
guide](business-runtime-profile.md) describes the subsequent offline image build.
Do not replace a failed fixed input with a moving `latest` download.

## License and source inventory

The lock records package metadata, including BusyBox and Git (`GPL-2.0-only`),
Linux (`GPL-2.0-only`), musl and Node.js (`MIT`), and Python (`PSF-2.0`). These
labels are the recorded package declarations, not a complete file-level license
audit. Other locked packages include GPL, LGPL, MPL and other licenses. Each
`source` link is a pinned Alpine build recipe with upstream source URLs and
patches; it is not itself a complete corresponding-source archive.
The business image has 45 packages and uses Bash for the CLI's normal command
tool. The diagnostic profile retains its original 44-package lock. Bash's
corresponding-source obligations remain part of any future binary distribution.

The [Linux project's license FAQ](https://www.kernel.org/category/faq.html)
identifies GPL version 2 and directs users of distribution kernels to the
distribution for their exact source. Before distributing a generated image,
collect its applicable license texts/notices and exact corresponding source,
patches and build materials where required, and match them to the generated
`runtime.json` inventory. The local builder emits runtime images and manifests;
redistribution notices and corresponding-source materials are separate outputs.
An APK hash or source-recipe link alone is not a corresponding-source package.

The [Claude Code license notice](https://github.com/anthropics/claude-code/blob/main/LICENSE.md)
reserves rights and refers use to Anthropic's Commercial Terms. The project has
not established permission to redistribute the vendor binary. Keep the vendor
blob outside Git and public release archives; users obtain the pinned input
directly from its upstream source under the applicable terms. The host App's
license does not confer an Agent subscription or provider entitlement.

## Evidence limits

The builders verify the pinned SHA-256 values. Publisher-signature verification
is outside this hash-verification workflow. The source inventory records package
origins; binary redistribution also requires the applicable notices and
corresponding-source materials. Local image construction, VM execution,
Developer ID signing, notarization and another Mac's installation use separate
procedures and evidence records.
