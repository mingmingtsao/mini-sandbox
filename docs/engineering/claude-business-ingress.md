# Pinned Claude business request admission

This increment parses the HTTP exchange emitted by the fixed Claude Code 2.1.309
business profile and binds the complete request to a host action. It does not
establish an external provider or a complete Agent task. Business credential
egress is disabled by the immutable `BusinessModelActivation` constant. There is
no preference, environment variable, guest field or saved-account override.

The gateway refuses business execution before consuming an approval. Transport
refuses again before reading a credential or constructing an operation. A Claude
dialect request also cannot use the older `prepareNative` entry point. Existing
native v3 and offline diagnostic tests retain their behavior. Enabling the new
route requires a separate source change after independent review of the precise
credential and final guest-output changes.

## Wire and identity

Only one HTTP/1.1 POST is accepted per connection. The selected runtime must
provide the actual VM/socket owner; HTTP supplies no run, connection, account,
host path, URL or authentication authority. `Host` must be the guest loopback
frontend `127.0.0.1:4061`. Its bearer value is the fixed, non-secret
`mini-sandbox-local-only` placeholder. It is never forwarded.

Duplicate headers, folded headers, controls, invalid header names, absolute
targets, unknown paths/query, `Transfer-Encoding`, `Content-Encoding`, `Expect`,
`Upgrade`, proxy authorization, additional API keys, pipelines and extra bytes
are rejected. An incomplete valid prefix remains incomplete; it is not EOF or a
successful request. The connection owner supplies the bounded receive deadline.

The business dialect accepts exactly this captured tuple:

| Selector | Accepted value |
|---|---|
| Method | `POST` |
| Path | `/v1/messages` |
| Query | `beta=true` |
| Anthropic version | `2023-06-01` |
| Anthropic beta | `claude-code-20250219,interleaved-thinking-2025-05-14,effort-2025-11-24` |

Unknown or reordered beta sets fail closed. The v4 approval envelope contains
this complete tuple, the original validated native body, streaming mode, run and
epoch, connection and account identity, and route/account versions. Any future
enabled dispatch reconstructs only those approved bytes. The only planned route
is the fixed host DeepSeek Messages endpoint; guest URLs are not accepted.

The existing v3 parser remains unchanged in scope. The new dialect additionally
accepts bounded text-only system sections after a user turn whose tool results
are complete, followed by assistant or end of input. System-first,
assistant-system, system-before-user, pending results and non-text system content
are rejected. System content and its position are preserved in the outgoing
native tree; the validation projection is never sent. This is supported by the
current provider's documented [mid-conversation system messages](https://api-docs.deepseek.com/guides/tool_calls/).

The [Claude gateway guide](https://code.claude.com/docs/en/llm-gateway-protocol)
documents the query and preserving version/beta selectors. DeepSeek documents
the [Messages beta/version behavior](https://api-docs.deepseek.com/guides/anthropic_api/).
These references support the selected dialect, not a claim of executed provider
interoperability. The policy remains thinking disabled before approval; no
thinking blocks, server tools, images or arbitrary semantic fields are admitted.

## Budgets and evidence

| Stage | Limit |
|---|---:|
| HTTP headers | 16,384 bytes and 64 fields |
| HTTP body | 65,536 bytes |
| HTTP request total | 81,920 bytes |
| Canonical native JSON | Existing ModelJSON 65,536 bytes / depth 32 / 8,192 nodes |
| Complete approval envelope | Minimum of grant message budget and 65,536 bytes |
| History | Existing 128 messages; complete history must fit the envelope |
| Tool definitions | Existing 64 tools; complete schemas must fit the envelope |

Admission exposes counts only: HTTP, headers, raw/canonical body, whole envelope,
history messages, tool definitions and encoded tool-result bytes. These are
measured values, not a declaration that a body was sent. No history, result or
semantic field is truncated to fit. Existing native response frame, queue and
aggregate limits remain in force.

`swift run BusinessIngressChecks` checks fragmented HTTP, framing/smuggling and
selector rejection, body preservation, one complete approval binding, grant
bounds, Stop and the immutable activation gate. It asserts zero credential reads
and zero network starts. `StructuredModelChecks` retains the prior native tests.
Real VM, external provider and GUI task evidence must be recorded separately.
