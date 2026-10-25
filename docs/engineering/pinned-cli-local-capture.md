# Pinned CLI local capture v1

Experimental headless protocol measurement only. No App authority, provider, model-success, MCP, GUI, workspace bridge or export claim. Existing runtime and diagnostic profiles remain unchanged.

## Explicit profile bounds

`pinned-cli-local-capture-v1` retains 2 CPUs, 1 GiB RAM, 64 MiB fresh private writable RAW disk, 256 MiB expanded image, 64 MiB image-file cap, 128 MiB compressed-image cap and all 4050/4051/4060 framing limits. A separate **read-only** RAW data attachment contains only the pinned 285,493,120-byte vendor ELF and any necessary zero sector padding; its exact size and SHA256 are verified before attachment. It is not a filesystem archive. No host extraction or host vendor execution is allowed.

Trusted guest initialization streams only that fixed blob into a dedicated bounded executable tmpfs at `/opt/agent-probe/claude`, verifies its digest and remounts read-only **before** imposing the 64 MiB child FSIZE limit. The allocation is within existing 1 GiB RAM, not a RAM increase. Fresh HOME/cwd/tmp use a separate 16 MiB tmpfs. The original private work disk stays 64 MiB. Failed materialization or memory exhaustion fails closed, not a larger implicit budget.

Only this named profile changes command wall time 15→55 seconds, guest session 60→75 seconds, host run 65→95 seconds and outer host wait 82→112 seconds (driver 115). Stop remains 10 seconds; child CPU remains 20 seconds, FSIZE 64 MiB, NOFILE 64. Version and help each have an 8-second wall deadline and 64 KiB transient output cap; only version-match and known-flag booleans leave the guest. The normal fixed launch lasts at most 30 seconds; owned TERM→2-second grace→KILL/reap follows. Capture retains its original 35-second lifetime; it is not restarted or extended. CLI stdout/stderr are `/dev/null`. Capture source is reused unchanged and returns static 503, never synthetic provider success.

Loopback is explicitly enabled; no NIC or host directory shares are attached. The host's actual VZ object binding remains the source of session identity. Only `lo`, routes and read-only block status are checked inside the guest. Only synthetic probe auth is present, supplied by the fixed replacement environment in `guest-launch.json`; no host environment, credentials, Keychain or `.env` is loaded.

Process-group cleanup is not containment of setsid escapes. Full callback-settled VM stop is required even after normal CLI exit. Inputs and ancestors must remain private/non-mutating throughout VZ's path reopen; read-only mode does not defend against hostile same-user/root mutation. Vendor artifact stays outside Git and is not approved for redistribution.

## Reproduction and final checks

Use new private directories outside Git for each output; keep all input files and ancestry non-mutating. The following commands consume the existing verified downloads and base bundle. Never execute the vendor binary on the host.

```sh
python3 Tools/AgentRuntime/vendor_data.py "$IMMUTABLE_VENDOR_SOURCE" "$NEW_PRIVATE/vendor.raw"
python3 Tools/AgentRuntime/build.py "$RUNTIME_DOWNLOAD_ROOT" "$DIAGNOSTIC_BUNDLE" "$NEW_IMAGE" --agent-probe
python3 Tools/WorkspaceTransfer/build_host.py runtime-probe "$NEW_PRIVATE/runtime-host"
codesign --force --sign - --entitlements scripts/vm-probe.entitlements "$NEW_PRIVATE/runtime-host/host"
codesign --verify --strict "$NEW_PRIVATE/runtime-host/host"
python3 Tools/AgentRuntime/verify_agent_vm.py "$NEW_PRIVATE/runtime-host/host" "$NEW_IMAGE" "$NEW_PRIVATE/vendor.raw" "$NEW_NORMAL_SESSION"
python3 Tools/AgentRuntime/verify_agent_vm.py "$NEW_PRIVATE/runtime-host/host" "$NEW_IMAGE" "$NEW_PRIVATE/vendor.raw" "$NEW_ACTIVE_CANCEL_SESSION" --cancel-active
python3 Tools/AgentRuntime/verify_agent_vm.py "$NEW_PRIVATE/runtime-host/host" "$NEW_IMAGE" "$NEW_PRIVATE/vendor.raw" "$NEW_START_CANCEL_SESSION" --cancel-start
```

The builder records the named profile, original and padded vendor sizes/digests, closure hashes, tmpfs budgets and deadlines in `runtime.json`. It includes the reviewed capture source byte-for-byte under `/runtime/capture.py`. The supervisor invokes its original entrypoint in a separate owned process with a readiness-only wrapper, preserves the original 35-second lifetime and applies a 37-second outer capture deadline. This differs from the proposed capture script location in the declaration: `/opt/agent-probe` is reserved for the vendor-only read-only tmpfs. Fixed vendor argv/environment/stdin are unchanged. Version/help use isolated check directories; the actual launch's exact HOME/cwd/tmp are freshly created afterward.

A next guest command checks both original groups absent, then tests a synthetic Python child that ignores TERM: the 2-second grace falls back to KILL, reaps it, and verifies group absence. It also exercises oversized-output rejection. That Linux regression is skipped by the macOS unittest runner and executed in the actual guest; a macOS group-probe permission error is preserved as a platform mismatch, not relabeled a PASS. Active cancellation reports `vendorExit: null` because VM stop supplies no vendor wait status; normal timeout retains the actual wait status. Full VM stop, including settled framework callbacks, is the containment boundary.

## Evidence discipline

The plan file's `NOT_RUN` is a declaration, not a runtime-result store. Store actual version-match/flags/exits, bounded capture metadata, memory observations, image/source/host digests and settled normal/cancel evidence in a new private evidence directory. Static 503 or timeout may establish measured request protocol, never a successful model turn or Agent task.

The initial unpadded vendor attachment was actually rejected by VZ: the ELF length is not sector aligned. The fixed representation is exactly 285,493,248 bytes: 285,493,120 ELF bytes plus 128 zero bytes. Its SHA256 is `c4e512ea944c420c80285b4c4bd817098d9845ac6aa6e423bbbb58b8d3a9bf43`. Both host and guest enforce the exact ELF digest and zero tail; no filesystem headers or arbitrary paths are accepted. The original vendor bytes have SHA256 `028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332`.

First actual isolated execution of the pinned 2.1.309 Linux aarch64 musl CLI passed its exact version check and all required help-flag checks. The fixed startup produced six actual POST requests at `/v1/messages?beta=true`, each with 45,508 body bytes, two messages and twelve tools. The unchanged capture returned static 503. At the 30-second probe timeout, owned TERM cleanup produced truthful vendor exit 143; the next guest command found its group absent, and VZ stopped with callbacks settled. This is protocol evidence, not provider compatibility or a model task. Subsequent runs may have different body bytes/counts; retain their own measurements rather than copying this first observation.

Measured first-run available guest memory was 459,112 KiB before CLI probes and at least 341,512 KiB at sampled points during capture; the child high-water RSS was 234,940 KiB. These are observations, not enforced memory reservations or a proof of the worst possible workload. The VM remained at 1 GiB RAM and the writable disk at 64 MiB.
