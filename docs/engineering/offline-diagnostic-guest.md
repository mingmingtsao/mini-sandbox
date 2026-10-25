# Offline diagnostic guest fixture

This is a diagnostic-only Linux/arm64 fixture. It does not start an Agent, a distribution bootstrap, a package manager, a login shell, DHCP, or any network-installed workload. The host must configure **no network devices, shared directories, or storage devices**. Guest reports are untrusted diagnostics, not proof of host-enforced isolation.

## Inputs and reproducibility

Required host tools: Python 3.9+ (validated with 3.9.6), Go **1.26.5**, and the locally supplied pure-Python **PySquashfsImage 0.9.0** wheel. The wheel is hash-checked before importing directly from its ZIP; no global installation is performed. The probe uses only the Go standard library. Compilation sets `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=v8.0`, `-trimpath -buildvcs=false -ldflags=-buildid=`, disables toolchain/module network downloads, and supplies an explicit minimal build environment.

Cache these exact upstream files before building (the builder never downloads):

| Input | SHA-256 |
| --- | --- |
| `alpine-minirootfs-3.24.3-aarch64.tar.gz` | `4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50` |
| `alpine-netboot-3.24.3-aarch64.tar.gz` | `0ac085f19648562d33deb8bfdc339d747e40f456a49a43385d468ea46a888147` |
| `PySquashfsImage-0.9.0-py2.py3-none-any.whl` | `a8ea154bf946f985c65fab7d8c08dc73da7ad47a0aebf0d13ae50ae56e369f90` |
| Resulting raw ARM64 `Image` (36,306,944 bytes) | `256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e` |

Upstream locations, for provenance and preparation only:

```text
https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/
https://pypi.org/project/PySquashfsImage/0.9.0/
https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/linux-virt
https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/busybox
https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.24-stable/main/musl
```

Hashes are integrity pins supplied for these inputs; they are not independently claimed signatures. The expected kernel release is `6.18.58-0-virt`. The builder dynamically reads the EFI zboot payload offset/size, validates its gzip compression and bounds, validates the decompressed ARM64 magic/header/size, and compares the raw Image hash.

Only selected **regular** tar/squashfs entries are read into memory, never extracted onto the host. The root filesystem contributes just BusyBox and the musl dynamic loader. `modules.dep` determines load order and actual dependency closure; each selected module must be ELF64 AArch64 with exact vermagic `6.18.58-0-virt SMP preempt mod_unload modversions aarch64`, and its embedded `depends` must match dependency metadata. For these inputs the closure is exactly `vsock`, `vmw_vsock_virtio_transport_common`, and `vmw_vsock_virtio_transport`.

Source files and the manifest use the same bounded regular-file reader: `O_NONBLOCK | O_NOFOLLOW`, descriptor type/size validation before reading, and an explicit read limit (8192 bytes for the manifest). Writerless FIFOs are rejected without waiting for a writer. Archive inspection permits only regular files, empty directories, the two fixed symlinks, and empty character-device records at the approved paths with exact major/minor numbers. `/init`, BusyBox, the probe, and the loader must be executable regular entries.

The initramfs has sorted `newc` entries, fixed uid/gid/mtime/inodes, and gzip mtime zero with no original filename. Only the controlled `/dev/console` and `/dev/null` device records are permitted; these are CPIO bytes, not host device nodes. Guest symlinks are created from fixed source-controlled values. PID 1 mounts proc/sys/dev, loads modules in order, starts the probe with an empty environment except fixed `PATH`, then stays alive until the host destroys the VM.

## Build and test

Run from the repository root. `SOURCE_CACHE`, `WHEEL`, `SCRATCH`, `BUNDLE_A`, and `BUNDLE_B` below are explicit local paths; scratch and both bundles must be outside the repository. Bundle directories must not already exist. All ancestors must be nonsymlinks, and their immediate parent must be owned by the caller.

```sh
python3 -m unittest discover -s Tests/GuestFixtureTests -v
GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOWORK=off GOENV=off \
  go -C Tests/GuestFixtureTests test -v ./...
python3 Tools/GuestFixture/build.py --source-dir "$SOURCE_CACHE" \
  --wheel "$WHEEL" --scratch "$SCRATCH" --output "$BUNDLE_A"
python3 Tools/GuestFixture/build.py --source-dir "$SOURCE_CACHE" \
  --wheel "$WHEEL" --scratch "$SCRATCH" --output "$BUNDLE_B"
python3 Tools/GuestFixture/inspect_bundle.py "$BUNDLE_A" "$BUNDLE_B"
```

Failure is nonzero. Existing output is never overwritten or removed. An interrupted/failed build may leave a newly created partial directory; inspect it rather than retrying into it. `bundle.json` is written **last**, only after the two artifact files are complete. Repeat builds must match both artifact hashes; comparison inspects the archive and static Go ELF without executing the Linux binary or launching a VM.

The offline suites contain **14 Python tests and 3 Go tests**. Python coverage includes one-second bounded subprocess regressions for source/manifest FIFOs, reader size/type/symlink rejection, a full inspection of a mutated newc `/init` block-device entry with recomputed manifest hashes, and adjacent type/path/device/payload/executable/symlink negatives. The small full-inspection fixture substitutes only the kernel pin; it does not replace archive or manifest validation. Module vermagic/dependency negatives exercise the real metadata checks through an in-memory squashfs-reader fixture, and ELF tests directly cover `PT_INTERP` and `PT_DYNAMIC`. The Go suite checks the unchanged golden frame, malformed frames, and ambiguous identities. Inspection of the existing two real bundles also passes with equal manifests and entry inventories; these offline checks do not execute a guest.

## Fixed host contract

`bundle.json` has exactly these keys: `schemaVersion`, `kernelFile`, `kernelSHA256`, `initramfsFile`, `initramfsSHA256`, `probeSHA256`, `protocolVersion`, `workloadSHA256`, `kernelRelease`. Versions are 1. Filenames are fixed sibling `Image` and `initramfs.cpio.gz`. Workload identity hashes UTF-8 canonical JSON (sorted keys, comma/colon separators, no spaces) containing only `schemaVersion`, `kernelSHA256`, `initramfsSHA256`, `protocolVersion`.

The only per-run inputs are read from `/proc/cmdline`:

```text
console=hvc0 rdinit=/init minisandbox.run_id=<UUID> minisandbox.epoch=<positive decimal UInt64>
```

The UUID and epoch are cross-checks, never the source of host authorization. The actual host socket device/session selects identity. The probe connects only to host CID 2, port 4050 (plus the explicit unregistered-port test at 4051). Every connect/request has a five-second total deadline. Frames have a four-byte big-endian length followed by exactly 34 bytes: version (1), type (1 ping / 2 pong), 16 RFC4122 UUID bytes, big-endian uint64 epoch, big-endian uint64 nonce. Maximum body length is 4096. The golden ping is:

```text
000000220101000102030405060708090a0b0c0d0e0f00000000000000010000000000000009
```

After a real matching pong, the probe separately sends type 255, an all-zero forged UUID, and a 4097-byte length header **without sending a body**. It tests connecting to 4051, then performs at most 32 additional pings while awaiting host stop. Observed reads, connection errors, and timeouts are reported, not silently interpreted as authorization decisions. The host must independently record the three rejection cases.

Bounded JSON includes kernel/proc information, interface names/flags, routes, mounts, module state, and actual IPv4/IPv6 TCP connection results to numeric documentation addresses. No DNS, environment dump, credential injection, or host file access occurs. These results cannot establish isolation by themselves. Boot, real virtio-vsock exchange, host rejection accounting, and destructive stop require separate host integration testing; offline builds and ELF/archive inspection do not claim a successful VM run.

## Redistribution checklist

Before distributing binaries, collect the exact matching upstream sources, Alpine patches/configuration/build recipes, copyright notices, and applicable license texts. Linux and its modules, BusyBox, musl, Go's runtime/standard library, and the host-only squashfs reader have separate license obligations; this fixture does not relicense them. Consult the licenses shipped with the precise source packages, preserve notices, and provide corresponding source when their terms require it. The wheel contains `LICENSE.GPL3` and `LICENSE.LGPL`; it is host-build-only and is not included in the guest. Redistribution notices and source offers are assembled separately from the local image build.
