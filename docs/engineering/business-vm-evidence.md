# Actual business VM boundary evidence

These checks run the concrete `BusinessVMSession` and pinned Claude CLI in an
actual Apple Virtualization VM. This document records the standalone VM and
connection-boundary cases. No provider or Keychain is used.
The guest has zero general network devices and zero host directory shares.

The 2026-10-26 evidence root (`$EVIDENCE_ROOT`) is the maintainer's private
artifact directory `mini-sandbox-artifacts-20261025`; it is not published.
Private logs and raw requests remain outside Git. `business-host-v5/build.json`
records every source hash and compile command. Its sequential matrix is
`vm-matrix-v5.json`; each case has its own exclusive `vm-<case>-v5/host.log`.

| Case | Actual result |
| --- | --- |
| cancel-start | VZ start invoked; Stop observed while start callback pending; no running event; actual stopped and callbacks settled |
| control-stop / control-expiry | No bytes or send calls after Stop/expiry |
| control-partial-stop / control-partial-expiry | 8,192 bytes accepted by the real socket before Stop/expiry; retry commits zero additional bytes and makes zero additional send calls |
| control-backpressure-stop / control-backpressure-expiry | Actual VM paused to prevent reads; first send commits 8,192 bytes, second send returns EAGAIN; retry after Stop/expiry commits zero bytes and makes zero send calls |
| workspace-stop / workspace-expiry | Real guest acknowledged the control start; workspace output after Stop/expiry commits zero bytes and makes zero send calls |
| model-ingress | Real CLI initializes, imports the two-file project and sends a 19,457-byte HTTP request through the real VZ owner; zero provider requests and no claimed tool loop |

All ten cases returned actualStopped/callbacksSettled/diskRemoved true with the
matching runtime/run/epoch. Expiry uses the authority's manual trusted clock
while the real VM and connection remain live. Send counters describe actual
host syscalls, not guest acknowledgments. Partial-frame cases intentionally
never deliver a complete command. The separate workspace cases establish the
guest received a complete allowed start.

The backpressure fault injection exists only under DEBUG or
SANDBOX_TEST_FIXTURES. `build_host.py business-probe` explicitly selects this
fixture build. A normal optimized App has no pause injection or loopback
provider factory. Normal permission responses additionally require the A/B
action-deadline producer and final-clock patches; this matrix does not claim
permission-action expiry coverage.

The initial MCP capture assertion expected `initialize` and failed safely.
`vm-mcp-ingress-v7/request.http` establishes what CLI 2.1.309 actually sends:
POST `/mcp`, `mcp-protocol-version: 2026-07-28`, JSON-RPC `server/discover`, string
ID `server-discover-probe-1`, and `_meta` containing protocol version, clientInfo
and clientCapabilities (roots and elicitation). Its full HTTP SHA-256 is
`d684f7220a3d17bd2b32a328ec6690ecf90b89ab9632b1ced3b65a9d78da58eb`.
No response was sent and the VM stopped. Discovery capture does not establish
an initialized MCP session, tools/list, tools/call or provider support.

Reproduce using private, canonical, owned paths. The output directory must be
new. The image is built by `build.py --claude-business-runtime-v1` from pinned
inputs; its `runtime.cpio.gz` SHA-256 in this run is
`e056dad63b978081d86f394198ef1b5810f990d4167bde3b2a1b0b6b4681e469`.

```sh
python3 Tools/WorkspaceTransfer/build_host.py business-probe "$NEW_BUILD"
codesign --force --sign - --entitlements scripts/vm-probe.entitlements "$NEW_BUILD/host"
mkdir -m 700 "$NEW_SESSION"
"$NEW_BUILD/host" "$BUSINESS_IMAGE" "$PINNED_VENDOR_DISK" "$NEW_SESSION" control-backpressure-stop
```

Each probe has a 60-second watchdog followed by actual VM teardown. Never reuse
a session directory or infer success from guest text alone. Preserve failed
logs and distinguish source/runtime hashes when combining results.
