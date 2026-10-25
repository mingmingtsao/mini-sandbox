# Agent runtime vertical increment (experimental, local-only)

## Proven scope

This is a standalone VZ acceptance harness, not an Agent, App, model gateway, or completed file bridge. It reuses the verified diagnostic kernel and builder validation helpers, adds a **separate** runtime initramfs, and attaches one exclusively created 64 MiB session disk. Original diagnostic image limits and ports 4050/4051 are unchanged. The workspace quota increment adds only its concrete native-check target to Package.swift and links the real Host/Contracts sources for standalone builds; it does not modify diagnostic sessions, App, workbench, or shared authority sources.

The real Linux VM runs Node, Python and Git, reads a synthetic project, observes its Python test fail, changes subtraction to addition, reruns the actual Python test successfully, and reads the changed bytes again in the same VM. The host checks the expected before/after SHA256, exit statuses, stdout/stderr chunk hashes, cancellation, and original fixture hashes. A second session starts on a distinct fresh disk. A startup cancellation check requires settled framework callbacks and actual stopped state before serial handles are released.

## Reproduction

Use a private artifact root outside Git and the previously verified diagnostic bundle. `downloads` must be a caller-owned directory not writable by group/others. Never execute the Linux package contents or fixture on macOS.

```sh
python3 -m unittest discover -s Tests/AgentRuntimeTests -v
python3 -m unittest discover -s Tests/GuestFixtureTests -v
python3 Tools/WorkspaceTransfer/build_host.py runtime-checks "$ART/runtime-receive-tests"
"$ART/runtime-receive-tests/host"
python3 Tools/AgentRuntime/fetch.py "$ART/downloads"
python3 Tools/AgentRuntime/build.py "$ART" "$DIAGNOSTIC_BUNDLE" "$ART/image-new"
python3 Tools/WorkspaceTransfer/build_host.py runtime-probe "$ART/runtime-host"
codesign --force --sign - --entitlements scripts/vm-probe.entitlements "$ART/runtime-host/host"
codesign --verify --strict "$ART/runtime-host/host"
python3 Tools/AgentRuntime/verify_vm.py "$ART/runtime-host/host" "$ART/image-new" "$ART/normal-new"
python3 Tools/AgentRuntime/verify_vm.py "$ART/runtime-host/host" "$ART/image-new" "$ART/normal-other"
python3 Tools/AgentRuntime/verify_vm.py "$ART/runtime-host/host" "$ART/image-new" "$ART/cancel-new" --cancel-start
```

The actual CLI (not only the wrapper) requires absolute paths without dot/parent components, caller-owned private image/session leaf directories (0700), and non-symlink ancestry owned by the caller or root without group/other write permission. Input files must be caller-owned, non-symlink single-link regular files without group/other write permission. **The caller must keep inputs, sessions and their ancestry non-mutating for the entire run.** VZ reopens verified paths: these checks do not establish immunity against a hostile process running as the same user, root, or concurrent owner mutations. Do not reuse a directory writable by another principal or an ACL that grants another principal write access.

All image/session outputs must be new; existing outputs and failed partial outputs are preserved. Image builds are offline after the pinned download step. Builds do not run APK installation scripts. The image contains no package manager installation step at task time.

## Artifacts and trust

`Tools/AgentRuntime/dependencies.lock.json` fixes 44 Alpine v3.24 aarch64 packages, exact URLs, byte counts, SHA256, package versions, source commit URLs, license expressions, dependencies and providers. It includes Node 24.22.1-r0, Python 3.14.8-r0, Git 2.54.0-r0 and e2fsprogs 1.47.4-r0. Initial lock bootstrap used the official HTTPS index. The downloader consumes this repository lock and enforces byte hashes; **it does not enforce APK signature verification**. Verification of a fixed downloaded package set is separate from the downloader's guarantees. Third-party source/license redistribution obligations need release review.

The kernel SHA256 is `256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e` (Linux 6.18.58-0-virt). Matching virtio-block/ext4 module dependencies are selected from pinned linux-virt and ABI-checked. Existing vsock modules and init building conventions are reused.

`runtime.json` records the image hash, finalized parent-inclusive entry inventory/hashes and dependency manifest. `inspect_runtime.py` independently parses generated CPIO and compares the exact entry sequence/set, modes/types, payload sizes and hashes, and checks trailer, device and path invariants before output is written. Diagnostic input bytes are captured once through bounded reads and validated by the runtime-local `RuntimeBundle.py` (same 64 MiB diagnostic expansion bound); subsequent image construction uses that immutable snapshot, not another unbounded gzip read. Archive input is read through bounded nonblocking/no-follow regular-file opens. Tar data is parsed in memory, never unpacked to the host. Traversal, duplicate paths, special files, unsupported parents, escaping relative links and invalid hardlinks are rejected. Guest-root absolute symlinks are rebased to relative guest paths; hardlink contents are resolved in memory. Metadata/install scripts are not included. The runtime-only CPIO writer supports UTF-8 package filenames.

Explicit separate budgets: 256 MiB uncompressed image, 64 MiB individual file, 20,000 entries; 128 MiB compressed-image host input; 2 vCPUs, 1 GiB RAM, 64 MiB private RAW disk. The actual image is about 120 MB uncompressed. No diagnostic 64 MiB parser bound is raised.

## Boot and control hooks

* Kernel command line: `console=hvc0 rdinit=/init`.
* `/init`: mount proc/sys/devtmpfs, load matching modules, format `/dev/vda`, mount it at `/work` with `nosuid,nodev`, copy only baked synthetic fixture files into `/work/project`, then execute `/usr/bin/python3 -B /runtime/guest.py`.
* Runtime is Alpine/musl, not glibc. Inspect a later Agent's ELF interpreter/dependency closure before trying it; glibc compatibility is **not** established.
* Agent addition point: add pinned, verified ELF/dependencies in `build.py`, then a trusted-host-selected argv in `AgentRuntimeProbe.commands`, and the same explicit executable allowlist in `guest.py`. Do not run the Agent on the host.
* Current executable allowlist: `/usr/bin/node`, `/usr/bin/python3`, `/usr/bin/git`; no shell interpolation. Guest command cwd is fixed `/work/project`. Environment is explicitly constructed; stdin is `/dev/null`. Interactive stdin/PTY is **not implemented**.
* Port **4060**: guest connects to host CID 2, host listener is bound to its actual per-VM `VZVirtioSocketDevice` object and listener identity. No packet-supplied run ID selects host context. Only one connection is accepted.
* Port **4061**: reserved for later model capture/bridge; no listener or model routing is present. No URL/credential routing is accepted on 4060. No NIC or directory-sharing device exists.

### Runtime v1 framing

4-byte unsigned big-endian body length, then UTF-8 JSON. Maximum body 16,384 bytes; receive buffer 16,388 bytes; 512 frames; host transmit queue 32,768 bytes; output chunks 4,096 decoded bytes; cumulative stdout+stderr 262,144 bytes. The standalone host includes `Sources/SandboxHost/RuntimeJSON.swift`, a runtime-local adaptation of the reviewed raw model JSON grammar. The build helper now also links the real shared Host/Contracts implementation required by workspace quota binding; this does not route runtime-control messages through a model gateway. It rejects decoded duplicate keys before dictionary erasure, Boolean/float/exponent integer coercions, unknown/missing/wrong-type fields, nesting beyond 8, and more than 128 JSON nodes. Native tests invoke the actual Swift receive and fragmented/coalesced ingest boundary; Python protocol tests are not evidence for that decoder. Headers outside bounds poison the guest parser or stop the host session. IDs are host sequential command IDs, not identities or permissions.

```json
{"v":1,"type":"launch","id":1,"argv":["/usr/bin/python3","-B","task.py"]}
{"v":1,"type":"stdout","id":1,"data":"BASE64","sha256":"64 lowercase hex"}
{"v":1,"type":"stderr","id":1,"data":"BASE64","sha256":"64 lowercase hex"}
{"v":1,"type":"exit","id":1,"code":0,"cancelled":false}
{"v":1,"type":"cancel","id":1}
```

Guest starts with `hello` (ID 0); its kernel/interfaces/workdir/fresh fields are diagnostics, not security authority. Host VM configuration independently records zero NICs/shares. Guest has one active process group, a 15-second command timeout, 20-second CPU limit, 64 MiB output-file limit and 64 open-FD limit. Command cancellation and leader/pipe completion kill/reap the owned guest process group before clearing active or reporting exit. The Linux guest enables child-subreaper adoption and bounds group cleanup to two seconds after leader wait; the fixed regression leaves a descendant alive after its leader and output pipes exit, then independently checks group absence in the next guest command. This does **not** contain setsid/process-group escapes or implement cgroup isolation. Host SIGINT/SIGTERM revokes the socket first and stops the VM. Run deadline 65 seconds, stop deadline 10 seconds, host hard wait 82 seconds, driver outer timeout 85 seconds. Unknown stopped state is a failure; handles remain valid while framework callbacks may still use them.

## Deliberate exclusions / next integrations

* No real Agent, provider credentials, external account, model round-trip or MCP execution.
* No production shared-lifecycle authority injection; this fixed synthetic acceptance harness must not be used as an App grant bypass.
* The default runtime profile has no file bridge; stdout digests are not file snapshots. A separate [workspace transfer fixture](workspace-transfer.md) now exercises bounded transport, frozen result review and new-directory export using only a synthetic source. It is not arbitrary project selection or App authorization.
* No reconnect/resume, persistent disk reuse, interactive input, PTY, generic model proxy or route chosen by the guest.
* The self-review/unit/VM evidence is not an independent security approval. Full application suites (including previously known failures) and release/distribution acceptance are separate.
