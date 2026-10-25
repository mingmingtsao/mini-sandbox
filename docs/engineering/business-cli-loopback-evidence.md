# Real CLI tool loop with fixed loopback model

On 2026-10-26, `cli-loop-fixture-v6` passed the complete diagnostic below using
the real pinned Claude Code 2.1.309 Linux CLI inside a no-NIC VZ VM. The model
was an intentionally scripted HTTP fixture on host loopback. This is not a
real-provider, App UI, strict C08 task-fixture or MCP acceptance claim.

The evidence root is
`/Users/caomingming/Documents/ChatGPT/mini-sandbox-artifacts-20261025`.
`business-fixture-host-v8/build.json` records the full source/compile inventory;
`cli-loop-fixture-v6/host.log`, `fixture.json`, captured request bodies and
`session/cli.stdout` retain the actual observations. The guest image is
`business-image-v5`, SHA-256
`76124ff1500810098e24a467d28e4e06da207ff7556b607e8e5738e3d75f2acb`.

The fixture returns four `tool_use` model messages followed by ordinary final
text. It never edits a project file or constructs a `tool_result`. It requires
the matching real CLI tool result in each subsequent model request before
advancing:

1. Read returns the imported implementation `return a - b`.
2. Bash runs `python3 -B test_logic.py`; the actual result contains
   `AssertionError` and is_error=true.
3. Edit changes only that implementation expression to `return a + b`.
4. Bash runs the same unchanged test and returns is_error=false.

The normal CLI asks for Bash, Edit and Bash permission. Each exact request is
approved by the test host through `HostCLIPermissionGateway`, including its
one-use action binding, immutable input, deadline and concrete final write.
Session permission suggestions are not applied. The first Read uses the CLI's
normal default behavior; no bypass-permissions argument is used.

All five model exchanges use the concrete VZ owner, full canonical approval,
prepared-network ownership fence, credential-reflection guard and native final
response gate. The accepted response sizes are 948, 1005, 1012, 1014 and 922
bytes. Request body sizes grow from 18,805 to 20,335 bytes; full approval grows
from 19,376 to 20,906. The gateway reports five dispatches, 97,770 cumulative
outbound body bytes, 1,440 configured header bytes and peakActiveRequests=1.
URLSession-generated wire headers are not included in that header metric.

After finished plus completed transfer, the VM physically stops and all
callbacks settle. Only then does `WorkspaceRunSession.sealAndAdopt` accept the
matching runtime/run/epoch report. The review has one change, `logic.py`.
Exported bytes equal the fixed implementation and original test bytes; both
original source files remain unchanged. The reviewed host tree SHA-256 is
`e263a4d06f497704be40f68a356adb6e9b9f5a56fca871cf086f5a18db65ada9`.
The transfer-wire digest has a separate domain and is checked separately.
No imported or exported project code executes on the host.

Earlier failed attempts are preserved. They found additional real CLI permission
metadata, the missing supported shell (BusyBox sh was insufficient), and a
diagnostic assertion that mistakenly compared different tree-digest domains.
The test refused to report a shell error as a failing acceptance test. The
business runtime now adds only pinned Bash 5.3.9-r1 to the 44 reused packages.

Reproduce with a fresh private output directory:

```sh
python3 Tools/WorkspaceTransfer/build_host.py business-fixture "$NEW_BUILD"
codesign --force --sign - --entitlements scripts/vm-probe.entitlements "$NEW_BUILD/host"
python3 Tools/AgentRuntime/business_fixture.py "$NEW_BUILD/host" "$BUSINESS_IMAGE" "$PINNED_VENDOR_DISK" "$NEW_EVIDENCE"
```

The fixture entry and loopback provider factory require SANDBOX_TEST_FIXTURES
and are absent from the normal App. The normal real-provider activation remains
disabled. The 150-second host watchdog and 180-second outer process bound are
independent of guest-reported success; failed logs are retained.
