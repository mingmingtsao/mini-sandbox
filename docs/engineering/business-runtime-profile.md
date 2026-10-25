# Claude business runtime profile

`--claude-business-runtime-v1` is a standalone image profile. It cannot be
combined with `--workspace`, `--agent-probe`, capture or structural-metrics
switches. Existing diagnostic profiles retain their previous contents and
budgets. The new profile includes the fixed Claude Code 2.1.309 Linux aarch64
musl executable through the verified read-only vendor disk; it does not include
the diagnostic fixture's `task.py`, script edit, static capture responder or
fixed "Do not run tools" prompt.

The replaced CLI environment explicitly selects `/bin/bash`. The business-only
dependency lock adds Bash 5.3.9-r1 to the existing 44-package cache. Its aarch64
APK is pinned by full SHA-256, the already pinned Alpine index's control checksum
and its data-section checksum; existing musl/readline dependencies are reused.
BusyBox `/bin/sh` alone was rejected by the real CLI's Bash tool and is not
claimed as sufficient. No package install script is executed by the builder.

The host sends a bounded task and optional MCP selection over control port 4060.
The guest then receives the selected project through the existing strict
workspace transfer protocol on port 4062. It starts the actual CLI using its
normal `default` permission mode and bidirectional `stream-json` control
protocol. Every `can_use_tool` request is forwarded to the host on 4065, and
the returned input must be byte-semantically unchanged before an allow reply
is delivered to the CLI. The driver never executes a model tool itself or
manufactures `tool_result` messages.

Model HTTP goes from guest loopback 4061 to the actual VM's host listener 4064.
The relay forwards bytes unchanged and has no upstream URL, authentication
header or host-path selector. `mini-sandbox-local-only` is a public placeholder,
not an API credential or VM identity. When the host selects MCP, a separate
loopback 4063/host 4066 path is configured. The host selects `mcp=false` when no
MCP connection is selected; enabled connections use the gateway's protocol,
resource-scope and action-approval checks.

The CLI output is preserved as bounded stdout/stderr chunks with SHA-256, marked
as guest diagnostics. The total cap is 131,072 bytes; a single JSON event is at
most 65,536 bytes. A task is at most 8,192 UTF-8 bytes. There are at most 64
HTTP and permission requests, two relay connections, 81,920 request bytes
including headers, eight MiB response bytes per connection, and 32 KiB queued
relay bytes per direction. The host's canonical request, approval envelope,
connection and lifecycle limits still apply independently; there is no
truncation of multi-turn history to make a request fit.

The command wall limit is 840 seconds, guest limit 855, host limit 900, and VM
stop limit 15 seconds. CPU, file-size and descriptor limits remain finite.
After normal process-group cleanup the guest remounts `/work` read-only and
takes a bounded file snapshot. Only after complete transfer and actual VM
stopped state may the host adopt the immutable result. Guest-reported test
success is untrusted and cannot replace observed CLI actions, file differences,
fixed test digests or independent validation.

## Build and resource selection

Use the already verified package cache and diagnostic base where accessible:

```sh
python3 Tools/AgentRuntime/build.py "$CACHE" "$BASE" "$NEW_IMAGE" --claude-business-runtime-v1
```

The builder writes `Image`, `runtime.cpio.gz`, the detailed `runtime.json`
inventory and a small strict `business.json` identity. `BusinessRuntimeBundle`
checks the identity and actual resource bytes before use. The vendor disk is
selected separately and must match the fixed full padded digest; no vendor
binary is downloaded or executed by this builder. These are local artifacts,
not a declaration that third-party redistribution obligations are fulfilled.

Python regressions exercise typed task admission, normal permission round trips,
unaltered file transfer, path/digest/replay failures, unsupported empty directory
results and profile exclusivity. They do not execute imported project code on
the host. The [business VM](business-vm-evidence.md),
[CLI loopback](business-cli-loopback-evidence.md) and
[MCP](business-cli-mcp-evidence.md) documents record concrete runtime observations.
