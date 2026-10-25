# Bounded Anthropic-native host request increment

`HostModelGateway.proposeNative(handle:connectionID:body:streaming:)` accepts a
bounded raw Anthropic request. This is a host API, not an Agent bridge, guest HTTP
listener, CLI compatibility result, GUI integration, or provider conformance claim.

## Preserved subset

- Exactly `deepseek-flash`, integer `max_tokens` in `1...8192`, and an explicit
  Boolean `stream` matching the host operation. No model remapping or token clamp.
- System string or ordered text-block array; message strings or ordered text,
  tool-use and tool-result blocks. Tool-result content may be a string or a text
  block array. IDs, input objects, result ordering, optional-field presence and
  strings/arrays stay intact. Existing tool-pairing validation is reused only as
  a validation projection; **that projection is never sent**. Validation-only
  encodings use unescaped slashes, matching canonical byte accounting rather than
  imposing a smaller effective limit on slash-rich messages, schemas or inputs.
- Full bounded tool `input_schema` objects, names and descriptions; tool choice
  `none/auto/any/tool` with a name only for `tool`.
- Exact `cache_control: {"type":"ephemeral"}` markers on supported blocks/tools.
  They are retained, not stripped; DeepSeek documents these markers as ignored,
  so this does not promise provider-side caching. TTL variants are rejected.
- `metadata.user_id` as a nonempty, control-free string up to 256 UTF-8 bytes.
- `output_config.effort` exactly `low`, `high`, or `max`, retained verbatim.
  Effort does not enable thinking or promise active reasoning with thinking off.
  Aliases and other output configuration fields are rejected, not mapped.

The host's explicit policy is **thinking disabled**. Incoming adaptive/enabled,
null, budgets or extra thinking fields fail closed. Omitted thinking is expanded
to `{"type":"disabled"}` **before approval**, captured in the approved envelope,
and sent upstream. Omission is not evidence of the provider's default; the official
thinking guide states that thinking is enabled by default.

Unknown fields/types, image/document/thinking/server-tool blocks, server-executed
tool definitions, URLs, headers, routing fields, experimental betas, context
management, and parallel-tool enforcement flags fail before approval or credential
access. All errors are static; unknown keys and request values are not logged.

## Immutable approval and execution

The v3 envelope embeds the complete validated JSON body alongside host-generated
run/epoch, account/connection/version and stream bindings. F03 `ActionBinding`
stores the actual canonical envelope bytes, not a mutable file/hash reference.
The envelope must fit **both** the grant message budget and the existing 65,536-byte
cap; raw body size is not used as a proxy for this measurement.

Execution consumes the existing immutable approval, rechecks identities, then
reconstructs only from approved bytes using the same sorted-key, unescaped-slash
canonicalization. `ModelTransport.prepareNative` shares the existing credential,
host-selected endpoint/headers, suspended operation and actual start path. Response
and SSE decoders, lifecycle start/cancellation and controlled receiver are unchanged.

ModelJSON remains capped at 65,536 bytes, depth 32 and 8,192 nodes with exact safe
integers only and duplicate-key rejection. Existing message/tool/name/description,
ActionBinding, grant and transport caps are unchanged.

## Evidence scope

Permanent checks in `StructuredModelChecks` exercise native proposal → approval →
actual URLProtocol-backed transport → controlled receiver, byte-exact outgoing
bodies, caller-data mutation, identity mismatches, strict malformed inputs and exact
wrapped boundaries. Slash-rich user strings, text blocks, tool schemas and paired
tool inputs have byte-exact transport regressions, ordinary/system/tool-result
controls, typed rejection checks and separate credential/resume/arrival counters.
They preserve all former 45 check names, including the original 37. These are explicitly
synthetic offline fixtures, not captured CLI/provider interoperability evidence.
Nonstream and fragmented structured SSE use the existing response decoders.

Real CLI, provider, guest transport, GUI and business consumer integration remain
unverified. The controlled receiver is private consumer-owned state, not an Agent
handoff or migrated legacy output API. No host tool execution is authorized here.

Primary compatibility references (retrieved October 24, 2026):
- https://api-docs.deepseek.com/guides/anthropic_api/
- https://api-docs.deepseek.com/guides/thinking_mode/
