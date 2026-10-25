# Headless diagnostic VM

This is a separate, real Virtualization.framework executable, not a simulation and not the desktop app's VM integration. It has no Agent, model, MCP, credential, file-transfer, authorization or network-forwarding service. No guest is launched by building or by `--capabilities`.

## Build and inspect

```sh
python3 scripts/build-vm-probe.py --configuration debug
codesign --verify --strict --verbose=2 dist/VMProbe/VMProbe
codesign --display --entitlements - --xml dist/VMProbe/VMProbe
dist/VMProbe/VMProbe --capabilities
swift run VMChecks
python3 Tests/VMChecks/test_build_vm_probe.py
```

The executable is signed ad hoc with **only** `com.apple.security.virtualization`. This does not change the app's signing or packaging. The builder refuses symlinked/unowned output, preserves previous owned output in a backup, and does not recursively delete directories. Ad-hoc signing is local-only, not notarization or distribution signing.

Capability inspection reports the actual framework support flag, CPU/memory limits and the executable's entitlement. It does not construct/start a VM, inspect the environment for credentials, or query Keychain. Configuration validation uses the verified bundle supplied to `--run`.

## Real run (explicit, after bundle verification)

```sh
dist/VMProbe/VMProbe --run --bundle /absolute/path/to/bundle --evidence-dir /absolute/path/to/new-evidence
```

The evidence directory must not already exist; its parent must exist and its path must not traverse symlinks. `security-events.jsonl` uses the existing synchronous JSONL audit sink; `result.json` contains the actual exit result and workload digest. There is no automatic fallback or simulation mode.

Exit statuses: **64** malformed CLI; **2** unsupported virtualization/missing entitlement; **1** failed preparation, host checks, audit, cancellation, deadline or stop; **0** only after an actual VZ connection yields a completely written pong, the host independently rejects unknown type, forged UUID and oversized header, and the framework reports actual `.stopped`. A successful framework start callback is not Linux-boot evidence. Guest text cannot satisfy any host check.

## Bundle and configuration

`bundle.json` schema version 1 names only sibling `Image` and `initramfs.cpio.gz`. The verifier rejects links, nonregular files, multiply linked files, oversized files, invalid digests, mismatched hashes and paths other than these fixed filenames. Each image is bounded at 128 MiB; manifest at 16 KiB. The workload SHA-256 hashes compact sorted-key JSON containing only `schemaVersion`, `kernelSHA256`, `initramfsSHA256`, and `protocolVersion`. The manifest's probe digest is metadata: its bytes are covered indirectly by the verified initramfs digest; this host does not extract/re-hash the embedded probe separately.

The local verified bundle is trusted host input and must remain unchanged during a run; hashes are integrity checks, not signatures or defense against another process controlling the same host UID. No guest can choose host paths.

Configuration uses `VZGenericPlatformConfiguration`, `VZLinuxBootLoader`, **2 CPUs**, **512 MiB** RAM, and checks actual framework limits and `validate()`. `networkDevices`, `directorySharingDevices`, and `storageDevices` are explicitly empty. There is one Virtio socket device and one serial console pipe. Kernel arguments are only console/init settings and host-generated run UUID/epoch; host environment is not inherited.

## Protocol and lifetime

Port **4050** carries a 4-byte unsigned big-endian body length. Lengths over 4096 are rejected immediately from the header, before reading/allocating a body. Only body length **34** is accepted: version byte 1, type byte 1 (ping), UUID's 16 network-order bytes, big-endian UInt64 epoch and nonce. A response changes only type to 2 (pong), then closes. No JSON, strings, nesting, arbitrary operation names or guest-selected routing are accepted. Parsing uses byte shifts, not potentially unaligned loads; parser errors are terminal.

Golden ping:

```text
000000220101000102030405060708090a0b0c0d0e0f00000000000000010000000000000009
```

The context retains the **actual VZ socket device** belonging to the VM. UUID/epoch only cross-check that context; they never select a session. There is one active connection, a 64-attempt lifetime budget, and a 5-second connection deadline. Socket reads/writes are nonblocking, at most a fixed frame per timer turn. The VZ connection owns its descriptor: the host retains the connection and calls its `close()` on the VM queue; it never `Darwin.close()`s that descriptor or transfers it to another descriptor owner.

All framework construction, properties, listener/delegate calls, callbacks and teardown execute on one serial VM queue. Each probe instance admits only one run, including concurrent callers. STOP immediately revokes context, removes the listener and closes socket connections. **Console attachment handles remain valid until start and stop callbacks have settled and VZ reports actual `.stopped`.** The initial `.stopped` state while a start callback is pending is not teardown evidence. Closing the serial attachment during asynchronous startup causes an uncaught `NSFileHandleOperationException` inside VZ; this is prevented by ownership/lifetime, not by catching the exception.

While stopping, each turn drains/discards at most 4096 nonblocking console bytes; it performs no protocol I/O. After startup settles, the host requests destructive framework `stop` when stoppable. Durable `vm.start.callback`, `vm.stop.callback`, `vm.stopped`, and `vm.console.released` records expose ordering. Run deadline is 60 seconds plus a 10-second stop deadline and a 72-second outer wait, unchanged. SIGINT/SIGTERM request the same cleanup. A wedged framework or synchronous audit filesystem can defeat timely callbacks; timeout reports failure and clean stopped state **UNKNOWN**, never success, and does not prematurely close framework-owned handles. Process exit is the last bound, not proof of clean VM stop.

Console capture is capped at **64 KiB**, emitted in bounded Base64 records with `guestDiagnostic` provenance; excess console data is drained/discarded. Host configuration/lifecycle/rejection records have `hostEnforcement` provenance. Rejection counts are derived only after successful audit append. Any audit error revokes the session and initiates shutdown. The event's `grantDigest` is computed by the existing `RunAuthorizationController.grantDigest(for:)` from a real immutable diagnostic `RunGrant`: verified workload digest, finite lifetime/resource limits, and no external connections. Host-generated snapshot identifiers refer only to this explicit diagnostic invocation, not model approval or imported workspace data. No full broker or application authorization integration is claimed.

## Validation scope

Parser/session tests cover partial reads, golden bytes, oversized header before body, exact length, version/type, truncation, extra bytes, terminal parser errors, forged UUID/epoch, cross-context connection/reply, concurrent connection, budget, timeout, after-stop use, audit failure, guest provenance and real JSONL host rejection. Packaging tests cover output ownership/link preservation. These are unit checks, not fake VM acceptance.

### Opt-in real lifecycle regression

```sh
python3 Tests/VMChecks/live_lifecycle.py --live \
  --probe dist/VMProbe/VMProbe --bundle /absolute/path/to/verified/bundle \
  --evidence-parent /absolute/path/to/existing/scratch --normal --cancel-attempts 3
```

Without `--live` this command refuses to launch. Each invocation creates unique evidence directories and spawns its own probe. Cancellation waits for the durable `vm.start` record, then signals only that exact child PID. The runner requires exit **1**, a completed host actual-stopped record, settled start callback, console release after stopped, no authorized ping/pong after `vm.stopping`, fresh run UUIDs, and a matching `result.json`. An abort, timeout, or missed pending-start window fails rather than being relabeled clean. It retains stdout/stderr, exact PIDs/signals and callback ordering in `lifecycle-report.json`. Normal mode additionally requires exit **0**, real pong and all three host rejection reasons. A runner timeout kills only its own child and is a failure, never stopped evidence.

The original signed binary was reproduced with this runner: SIGINT after `vm.start` and before its callback produced SIGABRT (Python return code **-6**), the serial-attachment `NSFileHandleOperationException`, and no stopped/result record. After the lifetime fix, a real normal run exited **0** and three pending-start cancellations each exited **1** with ordering `vm.start → vm.stopping(cancelled) → vm.start.callback → vm.stop.callback → vm.stopped → vm.console.released`. Deterministic VMChecks also cover pending-start initial-stopped and pending-stop release gates plus one-shot run admission.

These results describe the local normal-run and pending-start cancellation cases above. Framework-start failure, wedged callbacks, forced deadlines, cross-VM isolation, host-file access, credentials, resource exhaustion, and application authorization are outside the scope of these cases.
