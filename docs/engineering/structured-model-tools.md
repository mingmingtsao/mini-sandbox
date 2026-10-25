# Bounded structured model data

## Host protocol checks

The response-usage correction passes **37/37 structured groups**: all 29 existing
groups plus 8 focused usage groups. The separate model suite retains all 29 old
non-Keychain names plus 3 additive rejection groups (**32 distinct groups**).
`StructuredModelChecks` exercises production transport and gateway code using
synthetic URLProtocol responses for offline checks.

The first credential-present structured attempt on **2026-10-24 failed** on its
first nonstream request: gateway `outcomeUnknown`, one actual JSONL dispatch
intent, one unknown completion, and successful STOP. The streaming case was
**NOT_RUN** after that failure. Separate diagnostic attempts classified the same
request path as transport `invalidResponse` and isolated the response-field assumption: `ModelUsage` required **every
usage value to be a nonnegative integer**, but the valid response shape contained
integer `input_tokens`, `output_tokens`, `cache_creation_input_tokens` and
`cache_read_input_tokens`, plus string `service_tier`. The tier string value was
not retained. The regression fixtures are synthetic shape reproductions, not
captured provider bodies. The diagnostic observations identified response decoding,
not an HTTP/auth error; the original uninstrumented audit alone does not classify
its underlying error.

The corrected implementation passed independent review and a normal real-provider
rerun on **2026-10-24**: both nonstream and streamed tool round-trips passed,
with **four model task starts** in total. Each case received one `tool_use`, supplied
a matching **synthetic fixture result**, then received final text with `end_turn`.
This establishes the bounded host model-protocol path, not real tool execution.
The earlier failed attempts are retained in the execution record.

## Data, not authority

The package-level DTOs carry tool definitions, tool-use IDs and JSON arguments,
text results, and provider metadata. They do **not** execute tools, evaluate JSON
Schema, fetch remote schema references, install an Agent, or grant host/MCP
permissions. Provisional streamed tool data is not tool approval. An eventual
executor requires a separate authorization boundary.

Only the existing fixed model/routes are used. `FixedMessage(role:content:)`,
`ModelCompletion(text:)`, the text projection, and OpenAI text completions remain
available. A structured OpenAI request is rejected before credential access;
OpenAI `tool_calls`, `function_call`, or non-string content are rejected rather
than silently discarded. A `tool_calls` finish reason with ordinary string text
and no actual structured call retains the earlier text-only behavior.

## Supported bounded subset

- `ModelBlock.text`, `toolUse(id:name:input:)`, and
  `toolResult(toolUseID:content:isError:)`. Tool results carry a **string** body;
  nested result block arrays, images, thinking, server-side tools, and other
  block kinds are unsupported and rejected.
- Up to 64 uniquely named tools. Names use ASCII letters/digits/underscore/hyphen,
  1–64 bytes; tool-use IDs are printable ASCII, 1–128 bytes. Descriptions are at
  most 4096 UTF-8 bytes. Input schemas are bounded JSON objects with
  `type: object`; no schema evaluator or remote fetch is involved.
- `tool_choice` supports `auto`, `any`, `tool` with a declared name, and `none`.
  The optional `disable_parallel_tool_use` field is preserved on the wire, not
  treated as a provider-enforced guarantee. Multiple tool calls are supported.
- Tool uses belong to assistant messages; results belong to user messages and
  must immediately follow the corresponding assistant tool turn. Every ID must
  be globally unique within the request history; every pending ID needs exactly
  one result, before any ordinary text in that result message. Unknown, duplicate,
  missing, or mismatched results reject the request. Initial structured
  conversations start with a user message after any leading text-only system
  messages. This is data validation, not validation that a tool actually ran.
- Completion preserves ordered blocks and message ID, model, integer usage
  counters, nullable typed `serviceTier`, stop reason and stop sequence. Tool-only
  replies are never flattened
  into an empty-text success. Their text projection can legitimately be empty.
  Legacy text-only completion fixtures may omit metadata; structured tool replies
  require `type: message`, `role: assistant`, a nonempty printable-ASCII message
  ID (1–128 bytes, no required provider prefix), a nonempty control-safe model
  (at most 256 UTF-8 bytes), both nonnegative integer `input_tokens` and
  `output_tokens`, and `stop_reason: tool_use`. SSE message starts share the
  identity/usage validator; their stop reason and stop sequence remain unset.
- Response `usage.service_tier` supports exactly `standard`, `priority`, and
  `batch` as `ModelUsage.ServiceTier?`, separate from the nonnegative integer
  `values` dictionary. Initial absence or JSON null means no tier. Numbers,
  booleans, arrays, objects, unknown/empty/control/overlong strings are rejected;
  duplicate keys still fail in the raw parser. Other usage values must still be
  nonnegative integers: nested cache details and unknown heterogeneous metadata
  remain explicitly unsupported. Optional integer cache counters remain optional;
  null/noninteger cache counters remain invalid. No valid tier is silently dropped.

`ModelJSON` implements its own bounded raw parser before Foundation decoding.
It rejects duplicate decoded object keys (including escaped equivalents), invalid
UTF-8 and surrogate escapes, malformed tokens, excess nesting, excess nodes and
oversized values. Its numeric domain is **integer literals only, from
-9007199254740991 through 9007199254740991**. Fractions, exponents, negative zero,
non-finite forms and larger numbers are rejected, not rounded. Large identifiers
must be strings. This deliberately excludes schemas or tool arguments requiring
fractional numeric values; it is not arbitrary JSON-number compatibility.

Raw request ingress must use `FixedModelRequest.decodeValidated`, which performs
raw checks and rejects unsupported request/tool/choice fields before
`JSONDecoder`. The Codable initializer remains for trusted canonical bytes and
validates typed constructors, but cannot recover duplicate keys a third-party
Decoder has already collapsed. There is no guest ingress in this increment.
`cache_control` is not supported or claimed preserved.

## Unchanged and additional bounds

| Boundary | Limit |
| --- | --- |
| Canonical approved envelope | **min(grant.messageBytes, 65536 bytes)**, unchanged |
| Encoded HTTP request body | 1 MiB, unchanged |
| HTTP/SSE response | 4 MiB, unchanged |
| SSE physical line and decoded event | 256 KiB |
| Messages / blocks per message | 128 / 128 |
| Structured message, schema, or tool argument JSON | 65536 encoded bytes |
| JSON depth / nodes | 32 / 8192 |
| Individual decoded JSON string / accumulated text block | 65536 UTF-8 bytes |
| Message-delta events | 128 |
| Output tokens / concurrent requests | 8192 / 4, unchanged |

The approved envelope is version 2 with digest domain
`host-model-envelope-v2`. It canonically includes all supported structured
request values, tools and choice. Execution reconstructs only the immutable F03
approved bytes. No cap was raised; future CLI payload sizes must be measured
separately rather than inferred from these fixtures.

## Stateful streaming and audited delivery

Each prepared operation owns its own Anthropic stream decoder. It requires a
message start, contiguous indexed block start/delta/stop sequences, message delta
and message stop. Only text and `input_json_delta` fragments are accepted for their
respective block kinds. Tool starts contain the empty-object placeholder;
concatenated `partial_json` strings are parsed as one complete object at block
stop. Fragmented UTF-8 remains handled at the byte/line framing layer. Bad indexes,
wrong delta types, duplicate tool IDs, incomplete JSON, missing block stops,
unknown events, provider errors and early EOF fail closed. Pings are harmless.
A valid empty stream still requires a complete message lifecycle; a bare
`message_stop` is not one.

Until `message_stop`, each `message_delta` merges compatible stop fields into the
current metadata. Absent fields and explicit JSON null both mean no update: neither
erases a known stop reason or sequence. Repeated identical non-null values are
accepted; conflicting non-null reasons or sequences fail closed. A sequence may
arrive before its reason and is retained when a later delta omits it. Usage remains
cumulative and nondecreasing per field; omitted usage fields retain their values.
The tier merges separately: missing/null updates never erase an already known
value, a late first tier or identical repetition is accepted, and conflicting
non-null tiers fail closed. All integer counters, including cache counters, retain
their existing monotonic rules. An omitted usage object preserves all prior usage.
The 128-delta limit, required final reason, tool-use consistency, provider-failure
checks and rejection of EOF without `message_stop` are unchanged.

Every `message_delta` (including stop-reason-bearing metadata) and `message_stop`
is terminal delivery data. The gateway withholds all of them until the F03
completion append succeeds, then freshly validates liveness and cancellation
before **each** emission. Nonstream structured completion is also withheld.
Failed audit, STOP, cancellation and connection revocation suppress terminal
metadata as well as final markers. Previously delivered provisional events are
not retractable and must never be interpreted as tool-execution authority.
If the first terminal callback synchronously cancels its executing task, that
callback has already followed the durable completion append, but subsequent
metadata and `message_stop` are suppressed. Execution reports `outcomeUnknown`
without retrying, rereading credentials, or appending a second completion. The
existing completed audit record describes the finished upstream operation, not
successful delivery of every terminal event to the caller.

The sole gateway clock primitive, generation/revocation rules, F03 controller,
credential implementation, real suspended URLSession task, and final no-await
validation-to-`resume()` boundary are unchanged. Production durability still
requires a durable synchronous sink; a synthetic test sink is not disk evidence.

## Reproduction and current verification

```sh
swift run StructuredModelChecks
swift run HostIntegrationChecks
swift run AuthorizationChecks
swift run ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/PackagingTests -v
python3 scripts/build-app.py
codesign --verify --strict --verbose=2 dist/MiniSandbox.app
```

The metadata-merge revision passed **29/29 structured groups**, **38/38 host
integration groups**, **32/32 distinct non-Keychain model groups**, **17/17
authorization**, **7/7 contracts**, and all-products Debug compilation.
This revision also passed **4/4 API boundary**, **7/7 packaging**, and the
explicit Release `MiniSandbox` application build and strict signature verification.
The original independent-review probe was recompiled against this code and its
three metadata-update cases now pass. The earlier bounded offline implementation
had independent approval. That approval does not cover the new usage correction. The response-usage revision
passes **37/37 structured groups**, **38/38 host**, **32/32 distinct non-Keychain
model**, **17/17 authorization**, **7/7 contracts**, **2/2 permanent CLI tests**,
and all-products Debug compilation. This correction also passed fresh **4/4 API
boundary**, **7/7 packaging**, and the explicit Release `MiniSandbox` application
build with strict signature verification. Both earlier standalone metadata and
partial-delta probes were recompiled and passed. These results do not establish live-provider, Keychain,
Agent, VM or UI success. The separate normal live rerun below verifies only the
bounded host model-protocol path; the corrected code also has independent approval.

Before production edits, the new compiled regressions ran against the unchanged
decoder: **29 PASS / 3 FAIL / 32 groups**. All three official tier strings failed
both completion and fragmented SSE with `invalidResponse`, while numeric
`service_tier` was incorrectly accepted in both paths. This RED was an executed
behavioral failure, not missing-property compilation failure. The initial fix
passed **32/32**; added controls bring the final suite to **37/37** (29 original
plus 8 usage groups). Coverage includes **57/57** strict usage/raw-duplicate
rejections, **7/7** tier-conflict/numeric-update/counter-rollback cases, nullable
preservation and late/identical tiers, optional-cache compatibility, and gateway
returned-metadata preservation with held successful/failed completion audit in
both nonstream and fragmented SSE. These fixture runs made no live requests;
the real-provider run is recorded separately below.

The default `ModelTransportChecks` command also includes isolated Keychain CRUD.
That check has a prior environment BLOCKED result and was not invoked in this
credential-free verification. The 32 fixture groups were selected by their full
names, with actual PASS names deduplicated because selection uses substring
matching. All 29 pre-existing non-Keychain names remain, plus three additional
rejection groups. An unmatched selector exits 64; it is not a zero-test PASS.
Direct completion cancellation still reports **50 cancelled, 0 success, 0 other**.

Coverage includes nonstream and byte-fragmented SSE schema → tool use → matching
result → final-text round trips, multiple tools, immutable approved-request
reconstruction, synthetic credential/dispatch counts, bounded raw JSON, tool
pairing, malformed-stream matrices, canonical caps, and completion-audit
success/failure/STOP/cancel/revocation barriers. No tool is executed by the model
transport. Fixture audit barriers exercise ordering; they do not replace durable
production audit storage.

### Stricter v2 contract and retained regressions

Three earlier fixtures expected unsupported thinking or incomplete lifecycle data
to succeed. Their exact payloads remain as rejection regressions rather than
being deleted or accommodated by a permissive production fallback:

- Ordered `hello`, empty text, and ` world` blocks still yield `hello world`.
  Thinking/redacted-thinking blocks return `invalidResponse` instead of being
  silently discarded.
- The positive Anthropic stream now supplies full message metadata, indexed
  block starts/deltas/stops and terminal metadata. Mixed CRLF/LF and single-byte
  fragmentation verify ordered Unicode text and preserved usage/identity.
  The old incomplete stream must fail without a success-final event.
- A legitimate no-block empty Anthropic stream remains valid with message start,
  message delta and message stop: three empty-text metadata chunks, exactly one
  final. A bare `message_stop` is rejected. Both protocols' nonstream empty-text
  controls and OpenAI's existing `[DONE]` behavior remain covered.

The malformed-metadata regressions initially failed **2 of 22 groups**:
**15 of 24** completion mutants and **3 of 22** SSE-start mutants were incorrectly
accepted. The shared identity/usage validator now rejects **24/24 completion**
and **22/22 SSE-start** malformed cases without emitting chunks or raw response
content. Bounded opaque IDs without a provider-specific prefix, valid full tool
responses, metadata-free legacy text completions and complete empty streams
remain positive controls. A separate production-source probe also confirms that
empty IDs/models/usage, a wrong message type and a missing role no longer pass.

The metadata-merge regressions first reproduced three failures on the unchanged
production decoder: repeated stop-bearing cumulative updates were rejected,
reason-then-usage-only updates were rejected, and a sequence arriving before an
omitted-field final reason was erased. That run passed **22/25 groups** and failed
those three. After the merge correction, all **29/29 groups** pass, including
nullable no-update controls, the exact 128-delta boundary, and **11/11** negative
cases covering conflicting fields, usage rollback, provider failures after earlier
stop metadata, excess deltas, missing final reason and early EOF. Gateway barriers
hold four metadata deltas plus `message_stop` until completion audit, retain all
failure/STOP/cancel/revocation suppression checks, and verify synchronous
cancellation from the first terminal callback with a locked task holder.

## Opt-in structured host interoperability harness

The first attempt **FAILED** as recorded above. After the usage correction and
independent review, a normal (non-debugger) run on **2026-10-24** passed:

| Mode | First response | Synthetic fixture results | Final response | Model task starts |
| --- | --- | --- | --- | --- |
| Nonstream | `tool_use` | 1 matched result | `end_turn`, nonempty text | 2 |
| Stream | `tool_use` | 1 matched result | `end_turn`, nonempty text | 2 |

The actual JSONL contains **eight records**: four intent/completion pairs with
completed outcomes. Credential reads total four, both runs were stopped, and the
recorded audit SHA-256 matches the read-back bytes. Every streamed terminal
callback checked its action's completed record was already readable. No retry was
made. No credential, prompt, argument, response body or provider ID was persisted
by this harness. This is **REAL MODEL protocol + SYNTHETIC tool result**, not an
Agent, MCP executor, guest bridge, VM or native-UI acceptance result.

The harness is unchanged by the usage correction. Default
`swift run StructuredModelChecks` runs exactly 37 credential-free fixture groups.
Unknown or malformed arguments exit 64 before running any fixtures.
The only live command form is:

```sh
swift run StructuredModelChecks --live --evidence-dir /absolute/new/private-evidence
```

The parent directory must already exist, be owned by the current user or root,
and not be group/world writable. No path component may be a symlink. The leaf
must not exist: it is created with mode 0700. Evidence files are exclusive-create
0600 files; nothing is overwritten or automatically deleted. Paths containing
empty, `.` or `..` components are rejected rather than normalized.

The operator must separately verify that ancestor and inherited ACLs do not grant
other users write access. The harness checks POSIX ownership/modes, not ACLs, and
later file operations resolve paths again. This is a trusted-user/root-owned path
workflow without concurrent same-UID mutation, not an adversarial-filesystem
guarantee; mode bits alone do not establish privacy.

Only that explicit branch reads `TEST_DEEPSEEK_KEY` from the host process
environment. Missing/empty key exits 2 **before any evidence filesystem access,
credential-provider construction or networking**. There is no `.env` lookup,
CLI credential flag, Keychain access, URL/header override or test session.
Never put a key in a command line or an evidence file.

Two cases use the real `HostModelGateway` and default `ModelTransport` against
the fixed DeepSeek Anthropic route: nonstream and stream. Each has a fresh trusted
test-driver grant, an explicit proposal and host approval for each of two model
calls, a 64-output-token request limit, and no retries (at most four started HTTP
calls). Existing 60/120-second transport timeouts and 300-second per-case grants
bound execution without changing production limits or authority. A failed case
stops further cases; partial success is never a full PASS. Every installed run
is stopped on success or failure, and STOP failure fails the case.

The first request forces the declared `echo_fixture` tool. Every returned tool
use must have a unique bounded ID, the exact declared name and exactly the static
`text: sandbox-tool-check` input. Multiple uses are accepted and all receive
matching deterministic **SYNTHETIC tool results**, without executing any host or
MCP tool. All assistant blocks are retained in order. The second request disables
tools and must end with nonempty bounded text and `end_turn`. The summary means
**REAL MODEL protocol + SYNTHETIC tool result**, not Agent/MCP/VM/Keychain coverage.

The real `JSONLAuditSink` writes `audit.jsonl`. Every streaming terminal
`message_delta` and `message_stop` callback rereads that file and checks that its
own action's completed audit record is already readable. No in-memory substitute
is accepted. Final counts reconcile intent/completion pairs, known started calls,
and credential reads; indeterminate start accounting fails closed. The file
`summary.json` contains safe per-case status/counts, trusted run IDs, known stop
labels and the audit SHA-256. Neither prompts, arguments, response bodies,
provider IDs nor credentials are printed or persisted by the harness. Audits are
retained as their actual source, not synthesized summaries of imagined events.

Credential-free bootstrap checks were run after first reproducing that the old
runner incorrectly exited 0 and ran fixtures for unknown/live arguments. With
`env -u TEST_DEEPSEEK_KEY`, six malformed argument forms exited 64 and the valid
live form exited 2, with no fixture PASS or evidence creation. The updated default
suite passed **29/29**, host integration passed **38/38**, and all-products Debug
compilation passed. The early-return source gate precedes provider construction
and all filesystem/network operations; no dummy-key or live request was made.
These checks do not exercise the credential-present live branch. The permanent
CLI regression suite repeats the six malformed forms and missing-key case as two
unittest tests, without exposing a key to the tested process:

```sh
swift build --product StructuredModelChecks
python3 -m unittest discover -s Tests/StructuredModelCLITests -v
```

## Provider qualifications

The official Anthropic streaming/tool-use references define the tool
start placeholder and concatenated argument-delta lifecycle. The
DeepSeek Anthropic compatibility reference says `disable_parallel_tool_use`,
`cache_control` and `is_error` are ignored upstream. This implementation preserves
the two supported wire fields (`disable_parallel_tool_use`, `is_error`), without
promising those semantics are enforced. `cache_control` is unsupported.
Token counting is optional/fallback client behavior: no endpoint, estimated exact
count, or synthetic provider count has been added. No CLI compatibility is claimed.

The official Anthropic Python SDK usage schema defines optional response
`service_tier` with exactly `standard`, `priority`, or `batch`
(`github.com/anthropics/anthropic-sdk-python`, `src/anthropic/types/usage.py`).
This increment supports only that response metadata field, not request tier
selection, billing behavior or the rest of the SDK usage schema. DeepSeek's
Anthropic compatibility table marks request `service_tier` as ignored
(`api-docs.deepseek.com/guides/anthropic_api`); preserving a response tier makes no
claim about request-tier enforcement or the tier used by the failed live attempt.
