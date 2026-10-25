# Local coding client profile: measured availability, not permission

`claude-broker-coding-v1` is a second explicit client profile for pinned Claude
Code 2.1.309 (Linux arm64 musl). The stock launch and
`claude-broker-restricted-v1` JSON remain byte-for-byte unchanged. The new plan
copies the restricted replacement environment, stdin and every other setting;
only its profile label and these appended arguments differ:

```text
--tools Bash,Read,Edit,Write,Glob,Grep
```

This selects built-in **availability**, not permission or automatic approval.
There are no `--allowedTools`, permission-mode, skip-permissions, or grant changes.
The documented flag does not affect MCP tools. Existing empty strict MCP
configuration is retained. Current official documentation also warns that
omitting `EndConversation` need not remove it; the actual pinned version is
measured rather than assuming six tools from the requested list.

Primary reference, retrieved 2026-10-24:
`https://code.claude.com/docs/en/cli-reference.md` (`--tools` and `--allowedTools`).

## Explicit opt-in and boundaries

```sh
python3 Tools/AgentRuntime/build.py "$RUNTIME_DOWNLOAD_ROOT" "$DIAGNOSTIC_BUNDLE" "$NEW_IMAGE" \
  --agent-probe --structural-metrics --claude-broker-coding-v1
python3 Tools/AgentRuntime/verify_agent_vm.py "$SIGNED_HOST" "$NEW_IMAGE" "$READONLY_VENDOR_DISK" "$NEW_RESULT" \
  --claude-broker-coding-v1
```

The two client-profile flags are mutually exclusive. The coding flag requires
both existing image opt-ins. The native harness remains
`pinned-cli-local-capture-v1`; separate `clientProfile` and `launchSHA256` bind
the selected plan. The guest checks actual `--help` for an exact `--tools` token
and checks the entire argv before launching that argv. Its metadata reports only
Booleans, not vendor help/output. The verifier checks those observations.

Only coding-profile capture adds fixed-label counts for the six selected names,
`end_conversation_count`, `other_count`, `within_selected_set` and
`all_six_present`. Unknown names, names from requests, descriptions, schemas,
model values and prompts never escape. Existing complete structural measurements
remain present. The 15,000-byte retention threshold and 16,384-byte supervisor
pipe limit are unchanged. Capture always responds with static unsupported 503;
it does not rewrite requests, emulate success, or forward to a provider.

## Actual no-NIC VM measurement, 2026-10-24

Two builds reproduced the same kernel, initramfs and manifest. Final initramfs:
`c4e0febedecf3d352d64e8fc523d961cbb376b35ec2fc7ed078e0893f63332a5`.
The verified signed host and read-only pinned vendor were reused without changes.
Normal and active-cancel runs each created a fresh private disk, with zero NICs
and shares and unchanged resource/deadline budgets.

Six normal-run requests had identical retained measurements:

| Observation | Actual |
|---|---|
| Actual help token / actual launch argv match | true / true |
| Raw body / headers | 18,651 / 783 bytes |
| Expected model equality / max_tokens / stream | true / 8192 / true |
| Thinking / thinking budget | absent / absent |
| Beta header / endpoint | present / messages_beta |
| Effort | high |
| Messages / tools | 2 / 6 |
| Selected six counts | each 1 |
| EndConversation / other names | 0 / 0 |
| Within selected set / all six present | true / true |
| Maximum tool description | 1706 bytes |
| Maximum schema compact bytes / depth / value nodes | 2674 / 4 / 56 |
| Schema noninteger / unsafe integer / nonobject | 0 / 0 / 0 |
| Tool name-invalid / duplicate / unknown-field / nonobject | 0 / 0 / 0 / 0 |
| Tool name / description / schema presence | 6 / 6 / 6 |
| System blocks / text blocks / cache entries | 3 / 3 / 2 |
| System text bytes / maximum | 5591 / 5455 |
| System unknown types / fields | 0 / 0 |
| Top-level unknown fields | 0 |
| Metadata / output_config | present / present |
| context_management | absent |

The description maximum is below the unchanged 4096-byte limit. Raw body size
is smaller than the restricted profile's measured 64,893 bytes. Both outcomes
were achieved without dropping Bash, editing tools, descriptions, schemas or
system blocks in capture. The CLI itself generated the selected-tool request.
The six-tool observation is specific to this version and launch, not a promise
that `EndConversation` is always absent.

The vendor reached its original 30-second probe timer (exit 143); capture exited
0 and both owned groups were reaped. A subsequent guest command confirmed both
groups absent, stubborn-child cleanup and excessive-output rejection. The host
exited 0 for diagnostic completion and settled actual stopped before console
release. Active-vendor cancellation on the same image exited 1 and also settled
stopped; no vendor wait status or upstream cancellation was observed in that run.

## Captured request semantics

The capture records system blocks, metadata and output_config mismatches against
the capture profile. The business adapter defines handling and rejection of
cache-control, effort, beta selectors and message/tool-result ordering in
[Business request admission](claude-business-ingress.md).
Thinking omission does not mean provider thinking disabled. The beta opt-out
environment still does not produce a beta-free request in this measurement.

**Raw size and compact schema size are not Swift canonical wrapped ActionBinding
size or grant-budget fit.** Neither was measured here. No broker limit increased,
no protected Core/Swift/UI/registry surface changed, and no request fields were
silently flattened or discarded. Historical restricted-profile measurements
are recorded in the restricted-profile document.
