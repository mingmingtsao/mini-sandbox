# Actual CLI to local MCP service

The actual pinned Claude Code 2.1.309 CLI, running in the no-NIC business VM,
passed four bounded local MCP cases on 2026-10-26. These are actual HTTP service
calls and real CLI tool results; the model upstream is scripted loopback. The
scope is the fixed local repository protocol and resource grants. GitHub,
OAuth, other MCP protocols, App UI and real-provider tasks are outside this scope.

The private artifact root (`$EVIDENCE_ROOT` below) is the maintainer's
directory `mini-sandbox-artifacts-20261025`; it is kept outside Git and is not
published.
All four final cases use `business-fixture-host-v15` with its stable source and
contract-object hashes in `build.json`, and `business-image-v5`:
`76124ff1500810098e24a467d28e4e06da207ff7556b607e8e5738e3d75f2acb`.

| Evidence directory | Actual upstream observations | Actual CLI outcome |
| --- | --- | --- |
| cli-mcp-read-v3 | discover + list + one read A; 3 credential reads; 0 writes | repo-A-initial tool_result reaches next model request |
| cli-mcp-write-v1 | discover + list + one write A; 3 credential reads; exactly 1 write | vm-approved-once tool_result reaches next model request |
| cli-mcp-denied-write-v1 | discover + list only; 0 tool calls and 0 writes | gateway denial closes channel; CLI reports ECONNRESET as an error tool_result |
| cli-mcp-denied-resource-v2 | discover + list only; 0 tool calls and 0 writes | normal SDK permission for B is rejected by the A-only grant before an allow reply; run stops |

Every case stops the actual VM with callbacks settled and disk removed. The
first three also complete CLI/transfer settlement, adopt the matching frozen
workspace, and export its reviewed bytes. No project file changes. The denied
B run intentionally stops before result adoption. Repository B remains unchanged
in every case; the upstream service itself permits both A and B. The model
fixture never constructs a tool_result. It requires the corresponding actual
CLI result before it advances, except the explicitly stopped B case.

The driver imports the repository-owned `Tests/MCPGatewayChecks/claude_loopback.py`
server. A fresh random fake credential is passed only to the host over stdin,
bound to the selected connection/account/audience, and checked by the server.
It is never sent to the guest, model, logs or artifacts. Model request captures
are scanned for that value; host output is checked before reporting. The
normal SDK permission gateway uses the MCP connection ID and MCP resource
scope, independently of workspace permissions. The concrete MCP gateway then
requires its own exact host action decision and final native-output fence.

The actual CLI supplied metadata absent from the initial guesses. Discovery
uses 2026-07-28 `server/discover`, not a 2025 initialize handshake. Tools/call
adds bounded `claudecode/toolUseId` and numeric progressToken. Normal SDK
permissions include mcp_server={name:sandbox,source:dynamic} and
server_policy_ask_only=true. These fields are preserved in complete canonical
approvals but do not confer authority. Permission suggestions are never applied.
The fixed six built-in tools do not prevent the two configured MCP tools from
appearing in the actual model schema.

The initial strict rejections are preserved in cli-mcp-read-v1/v2. The final
four-case evidence is based on the corrected strict adapters. The current
denial response is connection closure, not a fabricated successful JSON-RPC
result or a claim of a polished denial message. Resource B refusal is proven
at the SDK permission boundary; this case does not bypass that boundary merely
to exercise a later one.

Reproduce in a fresh private directory, after building/signing the fixture host
as documented in business-cli-loopback-evidence.md:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Tools/AgentRuntime/business_mcp_fixture.py "$HOST" "$BUSINESS_IMAGE" "$PINNED_VENDOR_DISK" "$NEW_EVIDENCE" mcp-read
```

Other fixed modes are mcp-write, mcp-denied-write and mcp-denied-resource. No
arbitrary upstream URL, credential, tool name or command is accepted by this
driver. Guest/exported code is never run on the host.
# App-driven local services

`python3 -B Tools/AgentRuntime/business_mcp_fixture.py --serve NEW_EVIDENCE MODE`
starts only the two owned `127.0.0.1` services. `MODE` is `mcp-read`,
`mcp-write`, `mcp-denied-write`, or `mcp-denied-resource`. The private new
directory receives `ready.json` with `modelPort` and `mcpPort`, plus request
captures and final `fixture.json` observations. No App, VM, grant, or approval
is created by this mode. Services stop after the second model response, a
fixture error, SIGINT/SIGTERM, or the 1,800-second deadline.

The service-only MCP bearer is the public fake constant shared with the
`SANDBOX_TEST_FIXTURES` App configuration. The normal standalone probe still
uses a fresh random fake bearer delivered only through stdin. The service
observations do not themselves assert App success: inspect App approval,
actual VM stopping, and workspace evidence separately. A local smoke verified
both listeners, the fixed fake bearer, discovery, and signal-triggered shutdown
without starting an App or VM.

## Actual VM physical-stop boundaries

The additional standalone modes `mcp-retired-start` and `mcp-retired-send`
use `business-fixture-host-v16` and the unchanged business image v5. They are
intentionally unavailable in `--serve` mode because their stop/barrier driver
is part of the standalone probe. Both preserve the run's active grant while
stopping the concrete VM, isolating the VM-owner fence from run revocation.

* `cli-mcp-retired-start-v1`: the real CLI requested repository-A write and its
  normal SDK permission and exact MCP action were approved. A fixture-only
  credential-provider barrier held execution after approval consumption and
  before transport construction completed. After actual VM stop, settled
  callbacks, and disk removal, the barrier was released. The final start
  returned `notStarted`; additional HTTP resumes, upstream tool calls, writes,
  native send calls, and native bytes were all zero. The only upstream hits
  were the earlier discover/list pair. The grant was still active throughout.
* `cli-mcp-retired-send-v1`: the real CLI requested repository-A read. The
  approved upstream request completed and the concrete response was queued,
  without accepting any of its bytes. After actual VM stop and callback/disk
  cleanup, `acceptNext` rejected the retired owner. Native send calls, native
  bytes, and accepted final responses stayed zero. The upstream recorded one
  read in addition to discover/list, and zero writes. The grant remained active.

Each evidence directory contains `host.log`, `fixture.json`, and exact input
captures. Both modes retain unchanged original project/test bytes and perform
no workspace adoption after this intentional early stop. These are real VM
and CLI boundary checks against local scripted services.

