# Restricted Claude client profile (not broker compatibility)

`claude-broker-restricted-v1` is an explicit, opt-in **client configuration** for
pinned Claude Code 2.1.309 (Linux arm64 musl). It is not the original launch and
not a transparent request adapter. `guest-launch.json` and its historical
measurements remain unchanged.

The named JSON plan changes only the model argument to `deepseek-flash`, adds its
fixed profile label, and adds these three entries to the original replacement
(not inherited) environment:

- `CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192`
- `CLAUDE_CODE_DISABLE_THINKING=1`
- `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`

The synthetic stdin, fake authentication, empty strict MCP configuration, empty
setting sources, no updates, no session persistence, no NIC/shares and loopback
capture remain unchanged. This does not authorize a provider call.

## Explicit image opt-in

```sh
python3 Tools/AgentRuntime/build.py "$RUNTIME_DOWNLOAD_ROOT" "$DIAGNOSTIC_BUNDLE" "$NEW_IMAGE" \
  --agent-probe --structural-metrics --claude-broker-restricted-v1
python3 Tools/AgentRuntime/verify_agent_vm.py "$SIGNED_HOST" "$NEW_IMAGE" "$READONLY_VENDOR_DISK" "$NEW_RESULT" \
  --claude-broker-restricted-v1
```

The build flag requires both existing opt-ins. The runtime harness remains
`pinned-cli-local-capture-v1` with unchanged budgets; its manifest's separate
`clientProfile` identifies the restricted client, and `launchSHA256` binds the
new plan. The guest emits a fixed `clientProfile` record. This separation matters:
renaming the harness profile was rejected by the unchanged native host before
VM creation in the first attempt. That failed attempt is retained, not relabeled
as execution. A fresh final build was executed normally and actively cancelled.

Capture adds only a trusted fixed-model equality Boolean and an Anthropic beta
header-presence Boolean. It never exports the received model or beta values.
Neither mismatch results nor measurement flags transform requests. All responses
remain static unsupported HTTP 503, never synthetic model success.

## Actual pinned CLI measurement, 2026-10-24

Six requests in the normal final VM run had identical measured shape:

| Observation | Actual value |
|---|---|
| Request body / header bytes | 64,893 / 783 |
| Expected model equality | true (trusted configured model) |
| max_tokens / stream | 8192 / true |
| thinking / budget | absent / absent |
| output_config.effort | high |
| context_management | absent |
| metadata / output_config | present / present |
| Top-level unknown fields | 0 |
| Endpoint / Anthropic beta header | messages_beta / present |
| Messages / tools | 2 / 20 |
| System blocks / text blocks | 3 / 3 |
| System text bytes / maximum | 5758 / 5622 |
| System cache-control entries | 2 |
| System unknown types / fields | 0 / 0 |
| Tool maximum name / description bytes | 14 / 4285 |
| Tool name-invalid / duplicate / unknown-field counts | 0 / 0 / 0 |
| Tool schema compact bytes / depth / value nodes (maxima) | 1946 / 7 / 63 |
| Tool schema noninteger / unsafe-integer / nonobject counts | 0 / 0 / 0 |
| Tool name / description / schema presence | 20 / 20 / 20 |
| Tool type / cache-control presence | 0 / 0 |

Observed mismatches with the existing broker include description bytes (4285
exceeds 4096), system blocks/cache semantics, metadata and output_config/high
effort. **Beta header presence remains despite the opt-out configuration.** Only
presence was measured, so this does not identify which beta tokens remain or
prove that the environment variable was wholly ignored. The profile does not
achieve a beta-free wire request on this pinned version.

The normal capture reached its existing timer: vendor exit 143, capture exit 0,
owned vendor and capture groups reaped. The subsequent real guest check observed
both groups absent, reaped a stubborn child, and rejected excessive output. The
host returned 0 only for the diagnostic protocol and settled at actual stopped
before releasing console handles. One active-vendor cancellation on the exact
same image returned host exit 1 and settled stopped; vendor wait status was not
observed in that cancellation and is not claimed.

## Required adapter/consumer work, not implemented here

1. Explicit upstream thinking policy. Client **omission is not provider thinking
   disabled**. The existing encoder's explicit disabled policy must be selected
   and approved at the adapter boundary, not inferred from omission.
2. Represent or explicitly reject system text-block/cache-control semantics,
   metadata, output_config/high effort, and remaining beta protocol behavior.
   Do not silently drop or flatten fields.
3. Resolve over-limit tool descriptions through an explicit client capability
   choice or rejection. No description truncation or broker limit increase.
4. Validate complete messages, roles, content blocks, IDs, tool arguments/results,
   ordering, schema-declared type and numeric domains. Shape counts are not a
   semantic request decoder.
5. Construct the immutable approved native DTO and measure **actual Swift
   canonical wrapped ActionBinding bytes** against 65536 and the grant's
   messageBytes. Raw body and compact schema bytes do not prove envelope fit.
6. Bind native ingress to the real VM/session; enforce approval, expiry, audit,
   cancellation and final transport-start fences. Map streaming and decode real
   provider SSE/tool continuations into the controlled consumer with its own
   terminal-state/acceptance fence. No producer enqueue equals acceptance.

No live provider response, model task, tool success, full Agent workflow, real
userdata or general guest networking was exercised. Independent review remains
pending. Existing limits and protected Core/gateway/transport/UI surfaces were
not changed.

Configuration references: `https://code.claude.com/docs/en/env-vars` and
`https://api-docs.deepseek.com/guides/anthropic_api/`. Actual measurements above,
not current documentation alone, establish this pinned executable's behavior.
Retained verification evidence binds final sources, reproducible images,
unchanged signed host/vendor, RED/GREEN logs, the failed preparation attempt
and normal/cancellation traces.
