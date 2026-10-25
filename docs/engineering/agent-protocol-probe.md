# Pinned Agent protocol probe

## Status and scope

This document describes the executable **offline capture fixture**, its bounded HTTP metadata collection, and the pinned CLI launch contract. The fixture returns static failure responses and has no model-forwarding path. Production gateway behavior and canonical size limits are defined separately.

The first pinned artifact is Claude Code **2.1.309**, Linux arm64 musl. An official `latest` fetch on 2026-10-24 returned **2.1.310**; the older explicit pin is intentional. The artifact manifest separates upstream-declared checksum from actual downloaded checksum and gives the digests of provenance inputs. Hash agreement is not CLI compatibility or a verified publisher signature.

## Local fixture reproduction

From repository root, with Python 3.9+ and no third-party modules:

```sh
python3 -B -m unittest discover -s Tests/AgentProtocolProbeTests -v
python3 -B Tools/AgentProtocolProbe/capture.py
```

Use the environment's required build queue when applicable. The second command opens only `127.0.0.1:4061` for 35 seconds. It emits one bounded JSON document containing metadata, never request bodies. A valid request receives static HTTP 503, not simulated provider output. Unknown methods/routes and ambiguous framing receive static failure responses. This is not a generic proxy and has no upstream networking code.

Fixture-only limits: 1,048,576 bytes per body, 8,192 header bytes, 64 headers, 4,096 bytes per body read, 4,194,304 aggregate ingress bytes, 16 connections/records, three-second absolute **ingress** deadline. One connection handles one request; chunked transfer, content encoding, duplicate header names, duplicate JSON keys, folded headers, Expect and queued pipelining fail closed. Later pipelined bytes are discarded on close. Records contain fixed route enums, byte/read counts, known field names and types, list counts and authentication/SSE-accept presence booleans. Unknown field names, values, prompt, tool arguments, headers, tokens and malformed payloads are not logged. Raw data exists transiently in bounded process memory; there is no secure-erasure claim. Body-read counts are transport reads, not SSE frames.

The monotonic ingress deadline is fixed at handler entry and capped by the capture's remaining overall lifetime (35 seconds by default, configurable only downwards at the entrypoint). Reads use that remaining budget, with checks before and after each read and before JSON parsing. JSON parsing and metadata construction are bounded by input size but are **non-preemptible CPU work**: this is not a strict three-second end-to-end or 35-second process-exit guarantee. Expiry is rechecked after parsing, before a response, and immediately before retaining accepted metadata. Expired requests cannot start ingress or retain accepted shape metadata; they may retain only a static failure status. Accepted static-503 responses use at most one second and never more than the remaining ingress/lifetime budget. Expired-request cleanup may spend up to one additional second attempting a static failure response; output serialization and process scheduling are not hard real-time bounded. Guest-supervisor deadlines are described in the [pinned CLI runtime profile](pinned-cli-local-capture.md).

The larger fixture ceiling is measurement instrumentation only: it does not raise the production 65,536-byte canonical cap. A synthetic 70KB request proves the fixture can count bytes, not that Claude's normal startup fits any limit. Byte count alone would not establish canonical encoded-action compatibility even after a real capture.

## Image hook and guest launch

Install the independently verified artifact, not an installer or a host binary, as `/opt/agent-probe/claude` mode 0555. Install `capture.py` beside it. The musl artifact is ELF64 little-endian `EM_AARCH64` (183), with interpreter `/lib/ld-musl-aarch64.so.1` and `DT_NEEDED` entry `libc.musl-aarch64.so.1`. The image must provide and digest that loader/library closure. Static inspection does **not** verify late `dlopen`, subprocess dependencies, kernel compatibility or execution.

`Tools/AgentProtocolProbe/guest-launch.json` defines the launch contract. Start capture before Claude. Use an empty isolated HOME/cwd/tmp on guest-private tmpfs, replace rather than inherit the environment, and expose no host directories or general NIC. Host must attest actual VM/vsock binding and image identity; guest-supplied identity strings are not authority. Reserve runtime control 4060 and capture/bridge 4061; existing diagnostic channels stay unchanged. No model forwarding is authorized by this probe.

Before the request probe, inside that VM only, verify digest, loader resolution, `claude --version` and `claude --help` using the same cleared environment and bounded process runner. Check every configured flag against that pinned CLI. Then feed the fixed non-sensitive prompt on stdin. Discard CLI stdout/stderr; retain only exit codes and capture metadata. Kill only the owned process group at 30 seconds, SIGTERM then SIGKILL after two seconds. Remove ephemeral guest HOME after collecting metadata. This cancellation observes local process termination only, not upstream rollback.

Official CLI documentation describes print mode, disabled session persistence, explicit setting sources and strict MCP configuration.[1] Official environment documentation describes endpoint override, bearer-token override, disabled automatic updating and disabled nonessential traffic; marketplace auto-install has its own control.[2] These are documented configuration inputs, **not confirmation that the pinned executable honored them**. An empty environment and no NIC remain the actual containment boundary. The dummy token is not a credential; never substitute a live key here.

The first probe intentionally sends a normal print-mode startup request without removing built-in tools. It returns unsupported, cannot complete a model turn and cannot authorize tools. The model alias is a fixed probe choice, not a claim of support. Successful SSE/tool cycles require a separately reviewed real model bridge; no synthetic provider 200 or tool result is allowed.

## Independent protocol prerequisites

- **Claude Code:** capture real endpoint, bytes, known field types, tool/message counts and stream-related shape. Validate Anthropic Messages/SSE events, tool-use IDs and real tool-result round trips only with an authorized upstream. Endpoint metadata alone proves none of these.
- **Codex:** official configuration documents `wire_api = "responses"` as the supported provider protocol.[3] Requires a separately pinned Linux artifact and a Responses adapter with real event sequencing, function-call/output item correlation, cancellation and replay semantics. Chat Completions or a renamed endpoint is not a substitute. No Codex artifact was executed here.
- **DSH:** first-party DeepSeek adapter documentation describes `messages` and `chat-completions` selection; the former defaults to the DeepSeek Anthropic root.[4] The SDK's newline-delimited JSON-RPC transport is a separate control protocol, not the model API.[5] Pin its source/package dependency lock, Node closure, profile/plugin configuration, SDK framing and MCP behavior separately. No DSH compatibility or artifact execution is claimed.

## Licenses and release gate

Claude Code's first-party license notice reserves rights and points use to Anthropic Commercial Terms.[6] This is not an open-source redistribution grant. Downloaded bytes remain outside the source repository; do not bundle/release them until distribution permission and applicable terms are reviewed. Loader, system packages and each Agent's dependency licenses require an image SBOM/license review. No new account, subscription or credentials are required for this offline probe.

## Evidence boundaries

Unit and real-loopback TCP tests cover fixture behavior only. Provenance manifests and ELF parsing cover artifact identity and static requirements only. Actual CLI observations and runtime dependency details are recorded in the [pinned CLI capture evidence](pinned-cli-local-capture.md); model and MCP exchanges have their own runtime evidence records.

The launch tests assert the exact proposed argv (including the empty setting-source argument and strict empty MCP configuration), replacement environment, discarded stdout/stderr, and owned-process-group TERM/grace/KILL policy. They do not execute or validate a guest supervisor. The separately bounded vendor attachment and guest supervision are described in the [pinned CLI runtime profile](pinned-cli-local-capture.md); runtime artifact limits remain explicit.

Saved official-document search snapshots are digested separately in the manifest. Those digests identify the saved retrieval envelopes/excerpts, not complete upstream documents, CLI help output, or proof of pinned CLI behavior. Focused regressions use real TCP plus an injectable monotonic clock and parse barriers; slow/truncated bodies, exact byte-budget acceptance and populated-output privacy are separate checks. A 503 is always unsupported, never an Agent success.

## Sources

[1] https://code.claude.com/docs/en/cli-reference
[2] https://code.claude.com/docs/en/env-vars
[3] https://developers.openai.com/codex/config-reference
[4] https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/llm-deepseek/README.md
[5] https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/sdk/protocol/README.md
[6] https://github.com/anthropics/claude-code/blob/main/LICENSE.md
