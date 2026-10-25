# Pinned Claude business request admission

This increment parses the HTTP exchange emitted by the fixed Claude Code 2.1.309
business profile and binds the complete request to a host action. Business
credential egress is controlled by the compile-time `BusinessModelActivation`
constant, enabled on 2026-10-26 by maintainer decision (see
[business-egress-review.md](business-egress-review.md#启用记录)). There is no
preference, environment variable, guest field or saved-account override. The
history below describes the disabled-gate period in which this increment was
reviewed.

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

The exact optional transport/diagnostic allowlist is `accept`, `accept-encoding`,
`connection`, `user-agent`, `x-app`, the SDK's `x-stainless-lang`,
`x-stainless-package-version`, `x-stainless-os`, `x-stainless-arch`,
`x-stainless-runtime`, `x-stainless-runtime-version`, `x-stainless-retry-count`,
`x-stainless-timeout`, `x-stainless-helper-method`, and Claude session/agent/parent
agent ID headers. These are consumed locally without forwarding or logging and
cannot choose an identity or route. Other headers, including other `anthropic-*`
semantics, are rejected. This is a fixed-version subset rather than the general
gateway guide's recommendation to forward future fields automatically.

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
The selected dialect disables thinking before approval; no
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
bounds, Stop and the compile-time activation gate (now asserted enabled; an
approval without the actual VM owner is still rejected). It asserts zero
credential reads and zero network starts. `StructuredModelChecks` retains the prior native tests.

## Actual SDK header and concrete guest response owner

The image-v3 real Claude capture contains the fixed SDK header
`anthropic-dangerous-direct-browser-access: true`. This exact value is now part
of the complete approved selector tuple and is retained in the outbound request;
missing/false/unknown values reject. It grants no host authority. The captured
request admitted 19,457 HTTP bytes, 18,678 raw body bytes, 18,709 canonical body
bytes and 19,174 complete approval bytes with zero credential reads/network starts.

`makeVMNativeOutput` accepts only the connection minted by the actual VZ listener,
checks model service and the installed lifecycle/run/epoch, then takes its single
owned duplicate. The legacy AF_UNIX constructor keeps its original checks. The
VZ path holds the concrete connection lock before the lifecycle lock; the final
nonblocking send rechecks the owner, and terminal disposal retires the VZ original
outside both locks. Physical Stop closes owners synchronously, including the
result-preserving stop path.

`HostCLIPermissionGateway` binds each normal CLI stdio permission request, exact
arguments, runtime and channel into a one-use F03 action. Only the six profile
tools are recognized. Read/write paths must stay in the imported VM project;
commands execute only in the VM after an explicit host approval. The permission
reply is a concrete bounded VM writer with connection-scoped final checks. The
gateway never runs tools or constructs tool results. Native response, repair and
final-clock regression groups passed.

## Compile-time local provider fixture

Only a binary explicitly compiled with `-DSANDBOX_TEST_FIXTURES` contains
`HostModelConnection.localClaudeFixture(port:)`. Its constructor accepts a TCP
port but no host, credential, provider, URLSession configuration or headers. The
route is fixed to `http://127.0.0.1:<port>/anthropic/v1/messages?beta=true`, uses
an embedded public fake canary and disables proxies/cookies/cache. Redirects are
still denied. All schema-4 proposal, exact approval, dispatch and concrete VZ
output gates remain shared. Ordinary connections remain blocked before consume
and credential reads even in a fixture build. The fixture constructor, provider
and alternate endpoint do not exist in normal Debug or Release builds.

This fixture runs the actual VM/CLI against a local scripted provider.

Product schema-4 proposals use `proposeVMClaude` and bind the actual runtime and
channel IDs into the complete approved bytes. `makeVMNativeOutput` additionally
requires the exact same retained owner object; an equal run ID is insufficient.
Execution requires that concrete VZ output. Raw callbacks, in-memory output and
the old AF_UNIX constructor cannot dispatch schema 4, including in fixture builds.
The separate pure `proposeClaude` admission remains inspectable but cannot execute.

File tool paths now require explicit `/work/project/...` absolute paths (or the
exact root for Glob/Grep). Relative paths and tilde expansion are rejected.
Permission replies carry the immutable grant not-before time and action expiry
to the concrete writer; the lifecycle checks them at the final clock before each
send, including partial retries. Stop and connection revocation still apply.

S05 measurements now expose only request counts/sizes: actual resumed requests,
cumulative and maximum outbound JSON bytes, configured outbound header bytes and
maximum active transport operations. Configured headers deliberately exclude
headers URLSession adds on the wire; loopback capture records wire sizes
separately. Native progress reports maximum framed event bytes, maximum retained
queue bytes/events, total enqueued HTTP bytes and actual committed socket bytes.

`BudgetChecks` admits complete envelopes of 65,535 and 65,536 bytes and rejects
65,537; raw HTTP header/body/combined wire boundaries are checked at limit ±1.
Growing paired tool history at 1/8/16/24 turns retains every original message and
tool result (24 turns: 54,511 raw, 54,542 canonical, 55,007 approval bytes). A
32-turn 72,631-byte request rejects without truncation or any credential read.

Actual CLI Bash and Write permission captures include `display_name`,
`description`, and optional `decision_reason_type`. These bounded presentation
fields are retained in the full approved request. `permission_suggestions`
(including `setMode:acceptEdits` and `addRules`) are bound advisory metadata only:
the sole allow response is `{behavior:allow,updatedInput:<exact approved input>}`.
No session mode, persistent rule or `updatedPermissions` is installed. Unknown
request keys and wrong metadata types still reject.

The concrete model prepared operation also retains the same VM owner. Final
network start takes operation then owner locks before the lifecycle's trusted
clock, validates the claimed owner and only then calls URLSessionTask.resume.
Physical VM retirement therefore prevents a new request even when result-stop
intentionally preserves the run long enough to adopt files. Direct start() is
unavailable for a VM-bound operation; fixture/native diagnostics without a VM
retain their separate existing behavior.

The actual pinned SDK's MCP tool permission uses only
`mcp__sandbox__repo_read` / `mcp__sandbox__repo_write`, with exact
`mcp_server:{name:sandbox,source:dynamic}` and `server_policy_ask_only:true`.
These fields remain bound metadata and grant no authority. Typed `repo`/`content`
arguments resolve a separate configured MCP connection and the corresponding
`mcp` resource/operation scope; workspace permissions cannot authorize them.
Resource B is parsed so the explicit grant decision can deny it before a tool
allow reply. The subsequent actual MCP HTTP call still requires its own exact
gateway approval and concrete output. No permission suggestion is applied.
