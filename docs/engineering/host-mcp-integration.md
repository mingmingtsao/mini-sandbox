# Bounded host-only MCP integration

This document records the host-only MCP authorization fixture and its historical
verification results. The fixture uses a separate controller from the model
gateway and exercises no Agent, VM, external model/MCP service, real account, or
production credential store. The Claude client profile is described separately in
[Claude MCP client integration](claude-mcp-client.md).

## Boundary

`HostMCPConnection.testOnlyLoopback` is the sole endpoint factory: literal
`127.0.0.1`, a host-selected port, and fixed `POST /mcp`. Connection/account IDs,
account-binding and route versions, audience and credential provider are immutable.
There are no caller-supplied URL/header overrides. The provider's returned binding
must match the registered account and audience before task creation.

The pinned protocol is `2025-03-26`; the pinned server is
`host-loopback-fixture/1`; the adapter is `fixture-repository-v1`. Consult the
versioned MCP specification at
`https://modelcontextprotocol.io/specification/2025-03-26/basic/transports`.
Standard Streamable HTTP supports JSON and SSE responses. This implementation
accepts **only this fixture's JSON response subset**, and rejects SSE, sessions,
server requests, batches, unsupported notifications and methods. It does not claim
full transport, session, SSE, cancellation-notification or resumability conformance.
Its HTTP `Accept` header is only `application/json`; it does not advertise SSE.
The client advertises an empty MCP capability object. The fixture's advertised
resources capability does not enable resource calls in this gateway.

Each initialize, initialized notification and tools/list operation requires an
eligible scope, independent host approval, and durable F03 dispatch-intent before
credential access or HTTP start. Discovery distinguishes unknown, known-empty and
known-ready. Server identity and the canonical catalog digest/generation are bound
into approvals. A failed refresh invalidates the previous catalog synchronously.

The trusted adapter maps exactly `repo_read` to read and `repo_write` to write,
ignoring `readOnlyHint` as authority. Keys/types are exact, repositories are literal
A/B, and this slice permits only A through the gateway. A/write needs separate
eligibility and per-call host approval. The upstream fixture remains permissive for
both repositories and both operations using the same synthetic bearer.

The F03 envelope freezes the complete JSON-RPC payload, source tool-use ID, run,
epoch, grant digest, connection/account/audience/route versions, catalog generation,
schema digest, resource and operation. Execution accepts only an opaque approval
and reconstructs the request solely from the consumed canonical bytes.

## Limits and lifecycle

- Canonical envelope and response: at most `min(grant.messageBytes, 65536)` bytes.
- JSON parser: depth 32, 8192 nodes, duplicate-key rejection and safe integers.
- Write content: 16384 UTF-8 bytes. Result text: 32768 bytes, at most 16 text items.
- Registry and installed-run storage: at most 32 entries each; no run eviction API.
- Concurrent operations: at most `min(grant.concurrentRequests, 2)` per run.
- Existing F03 pending/ticket bounds apply; one buffered final HTTP body per call.
- Ephemeral uncached URLSession; no redirects, cookies, credential storage, proxies,
  retries or fallback. Request/resource timeouts are 3/5 seconds.

Preparation reads a bound credential but leaves the task suspended. Final run/action
clock validation and actual `resume()` have no intervening suspension. STOP,
connection revocation/update and catalog invalidation change actor state and cancel
operations before awaiting authority reconciliation. Grant expiry latches terminal
revocation through the centralized clock. Responses are released only after F03
completion audit and fresh liveness/cancellation checks. Started failures return
outcome-unknown; known pre-start failures are distinct. Neither RPC/provider/tool
errors nor response loss produce successful tool results.

Before the completed-success audit, the transport checks the **decoded, assembled
outbound text** against the exact bearer used for that request. A reflection is
rejected, not silently redacted: it returns outcome-unknown, records unknown, and
cannot create an `MCPCompletion` or successful model tool-result. This covers plain
text, an Authorization/Bearer prefix, JSON escapes, and a token split across adjacent
text items. Ordinary content and an unrelated `Bearer` word remain unchanged.
The comparison value stays private to the prepared transport operation and is
released after validation or cancellation/failure; there is no provider re-read,
approval-envelope field, caller DTO field, audit field, or logged credential.
This is an exact-active-credential reflection check, **not generalized encoded-secret
detection or DLP**, and does not promise zeroization of library memory copies.

## Reproduction

Run from the repository root. The authorization, host-integration and default
MCP commands currently exit nonzero for the retained security regressions:

```sh
swift build -c debug
.build/debug/AuthorizationChecks
.build/debug/HostIntegrationChecks
python3 Tests/MCPIntegrationTests/test_loopback.py
python3 Tests/MCPIntegrationTests/test_loopback.py --scope independent
.build/debug/MCPGatewayChecks --transport-unit
python3 Tests/MCPIntegrationTests/test_driver.py -v
python3 -m unittest discover -s Tests/Fixtures/host_services -v
.build/debug/ContractChecks
.build/debug/StructuredModelChecks
```

The Python driver launches the built `MCPGatewayChecks` executable. The executable
requires driver input over stdin; it is not a standalone no-input success check.
The driver mints a short-lived synthetic OAuth token and transfers it only through
stdin, never argv, environment, files or logs. The MCP path uses the **default real
URLSession transport**, not URLProtocol. Model turns use offline URLProtocol
fixtures; the negative continuation does not contact any model service.

A same-origin test-only response wrapper preserves the unchanged fixture's Host,
bearer, audience and routing checks. Its MCP response-drop hook runs after the
original MCP write mutation. The driver independently reads repository state after
loss, verifies one mutation request, and rejects retry/replay. Redirect checks use
a separate loopback origin and assert zero second-origin requests. Assertions are
outside HTTP callbacks.

Every phase reports observed cumulative MCP credential-read counters before/after
the phase, not just an expected literal. Both the Swift harness and Python driver
assert the delta; the driver checks continuity, actual fixture ingress counts,
unique phase names, and the exact expected result set. Negative cases require the
specific typed gateway/authorization error, rather than accepting unrelated errors.

Disk audit checks use the real `JSONLAuditSink`: each provider read verifies the
corresponding intent from the JSONL file, and a completion barrier verifies the
completed record from disk before the caller can receive a result. Reflection
produces a durable unknown record. Injected failures at the synchronous sink's
intent/completion append boundary suppress dispatch or result release and revoke
the run; these are **injected append failures**, not a physical-disk-failure test.
Temporary audit files contain only security events and are removed after the checks.

The child pipe reader has overall/inactivity deadlines (90/10 seconds by default,
configurable using `--overall-timeout` and `--inactivity-timeout`) and output bounds.
Silence, partial output, and stdout EOF without process exit cannot wait forever.
Only the `Popen` child created by the driver is killed/reaped on failure; no process
is found or killed by name. Child output is restricted to static protocol messages,
counts and booleans; arbitrary child stdout and stderr are not forwarded.

## Recorded local results

- Compiled RED: approved A/read failed because the gateway behavior was missing;
  unauthorized B/read and ungranted A/write regressions executed. This was not a
  missing-symbol/compiler RED.
- Compiled handoff RED: the completed offline tool-use could not create a proposal.
- Compiled schema-refresh RED: an unrecognized replacement schema incorrectly
  preserved known-ready state; the retained regression now requires unknown state.
- Initial local coverage: 42 distinct integration phases, including control audit pairs,
  approved read/write, raw ingress denials, immutable argument bytes, catalog/schema
  changes, response failures, redirect refusal, uncertain write, audit failures,
  STOP/revoke/cancel/expiry intent barriers and STOP during completion audit. All
  those phase names and the original broad-upstream/uncertain-write proof remain.
- Credential-reflection RED: all four authenticated loopback variants returned a
  completion and successful model tool-result, with completed rather than unknown
  audit. The permanent regressions failed behaviorally before the transport fix.
- Credential-reflection GREEN: all four variants block completion and handoff,
  record unknown, and make exactly one upstream request and credential read with
  no retry/replay. Both ordinary-content and unrelated-Bearer positive controls pass.
- Prior correction GREEN: **60 distinct MCP phases, 84 gateway upstream requests,
  86 observed credential reads**. The two extra reads are binding-mismatch/provider
  failures before HTTP start. These totals exclude the four direct upstream
  permission proofs and the independent readback after the uncertain write.
- Driver deadline RED: the silent child exceeded the outer watchdog before the
  bounded pipe reader existed. Driver GREEN: **7 checks**, covering inactivity and
  overall deadlines, partial output, EOF-before-exit, nonzero exit, invalid selectors,
  and cleanup of the owned child.
- JSON-only Accept RED: the real loopback request advertised unsupported SSE;
  the same request-header assertion passes after narrowing the advertisement.
- Existing unchanged suites: fixture 23, authorization 17, contracts 7,
  host integration 38, structured model 37; Debug all-products build succeeded.
  The correction also passed the 32 distinct non-Keychain model groups, API boundary
  4, packaging 7, and an explicit Release application build with strict signature
  verification. These results are separate from the still-unexecuted matrix below.
- Invalid executable selector exits 64; invalid driver selector exits 2; failed or
  timed-out children make the integration driver fail nonzero.

The model handoff proves completed **offline** tool-use → independent MCP proposal
→ explicit host approval → real loopback read → matching tool-result ID → next
**offline** model turn. It is not real Agent/model/external-MCP interoperability.

### Bounded matrix extension: partial, stopped on behavioral RED

The response-limit extension passed **79 distinct phases**, retaining all original
60 names and the four reflection variants plus two controls. It observed **109
gateway requests and 111 cumulative credential reads**. The additional 19 phases
are three discovery setups and 16 boundary cases:

- Grant byte cap 4096 and hard byte cap 65536 (with a larger grant of 131072), each
  tested at the exact cap and one byte over, with declared Content-Length,
  connection-close/unknown length, and actual HTTP chunked framing.
- Exact-cap controls are valid JSON padded with trailing whitespace, returning
  unchanged text. Unknown/chunked bodies are written in 1024-byte pieces; this is
  real loopback transport evidence, not manual URLSession delegate callbacks and
  not a claim about operating-system packet or delegate-callback boundaries.
- Assembled text of exactly 32768 UTF-8 bytes, and 32769 bytes, in one or two text
  items. Multibyte content distinguishes bytes from character count. Individual
  strings remain below the parser's 65536-byte string limit and the whole JSON
  body remains within the response cap.
- Every negative response returns typed outcome-unknown with an unknown audit,
  no completion, one credential read, one ingress hit, and rejected approval
  replay. Positive outputs are compared exactly.

The subsequent pulse-clock run completed **87 passing phases**, then failed
`pulse-deny-2`; `pulse-deny-3` was not reached. This is **not an overall PASS**.
All four proposal clock positions, all three approval positions, and the first
deny position passed. Each uses a controlled 900-second grant and a single sample
at its expiration boundary followed by valid samples; the system clock is not
changed. Run state is inspected immediately, before a new proposal can repair it.

**Retained finding:** `AuthorizationController.hostEvent` samples the shared clock
while producing the explicit-deny event, but does not validate grant time.
`HostMCPGateway.hostDeny` checks only before and after its authority await. A pulse
at the intervening audit timestamp is recorded at grant expiry, then the valid
post-await sample permits success without latching revocation. Observed:
`samples=3`, `fired=true`, `latched=false`, `audit_expired=true`, `error=none`;
a subsequent proposal is accepted. The failing phase has **zero credential reads
and zero HTTP hits**. No expired HTTP dispatch is claimed by this reproduction.
The retained assertion requires terminal revocation after the sampled expiry;
neither production behavior nor that expectation was changed to obtain GREEN.

Both Debug all-product builds succeeded. The matrix stopped on this production
behavioral RED; the existing driver and unrelated suites were not rerun afterward.
Production sources, Package.swift and the base host fixture remain unchanged.

### Independent continuation: passed scopes, full suite still FAIL

The explicit `--scope independent` selector passed **40 exact, deduplicated
phases**, with **68 gateway HTTP requests and 69 observed MCP credential reads**.
It does not run or hide the default suite's clock failure. Its result and success
marker explicitly retain `KNOWN_RED_pulse-deny-2`. The complete phase-name set and
per-phase before/after read counters are in the driver's JSON result, not an
inferred aggregate. Coverage added against already-correct code is coverage GREEN,
not a fabricated TDD RED or a production fix.

Passed independent scopes:

- **Saturation:** grant concurrency 1 and a larger grant concurrency 8 constrained
  by the existing hard cap 2. The original authenticated handler reaches actual
  MCP responses before a test-only condition gate holds them. Each ingress is
  acknowledged over the driver's static stdin/stdout protocol before the next
  operation starts; no sleep or assumed task FIFO establishes saturation. An
  additional approved operation returns typed `busy`, with no new intent,
  credential read or ingress hit. That *same approval* succeeds after one held
  operation completes, fails with HTTP 503, or is cancelled, including while the
  second cap-2 operation remains held. Gate waits are bounded to two seconds;
  callbacks record timeout state and the driver asserts it outside callbacks.
- **Action-only expiry:** a 900-second grant isolates the 300-second action
  deadline. A test audit callback advances time after intent, or a credential
  provider callback advances it after preparation. Both return typed `notStarted`,
  produce zero HTTP starts and exactly 0/1 MCP credential reads, record failed
  completion, leave the run nonterminal and permit a freshly approved recovery
  read at the advanced time. Not-yet-valid propose/approve/execute representatives
  return typed `grantNotYetValid`, remain nonterminal and recover at valid time.
  The frozen existing pulse cases were not changed.
- **Stale catalog completions:** two actual concurrent tools/list responses are
  held across catalog invalidation, account replacement, route replacement and
  STOP. Immediate state and old approvals are checked before settling old calls.
  Both old calls return typed outcome-unknown and cannot restore authority.
  Final unknown discovery is accepted as fail-closed; no winner-ready invariant
  is invented. Explicit rediscovery (and a new version-bound run where needed)
  restores known-ready state and an independently approved read.
- **Negative model handoff:** real `HostModelGateway` execution through an offline
  URLProtocol yields B/read, ungranted write, host-denied and unapproved proposals,
  non-tool output, truncated tool output, provisional SSE then EOF, and transport
  failure. These cause zero MCP starts/reads and no next model turn. Truncated tool
  output is rejected by the existing model parser itself with typed gateway
  outcome-unknown; it is not forced into a completed handoff DTO. Provisional
  callbacks actually occur but no terminal callback or completion escapes. All
  **nine offline model requests and nine model credential reads** are independently
  observed, audited and reported separately from MCP counts. An approved model-
  proposed MCP write commits before response loss, returns unknown, cannot replay
  or yield a tool-result, and triggers no next model turn. A separate real HTTP
  readback proves the mutation; this readback and the four broad-upstream A/B
  controls are excluded from gateway HTTP totals.

Separately passed: **Debug transport UNIT 4** (`@testable`, no public production
hooks), **driver 9** (the original seven plus direct line/cumulative output-limit
tests), fixture **23**, authorization **17**, contracts **7**, host integration
**38**, structured model **37**, and Debug all-products build. The UNIT mode uses
suspended tasks and manual delegate callbacks to test cancel-before-finish,
finish-before-cancel, repeated completion and repeated validation. Its **four
preparation credential reads and zero HTTP starts** are reported separately;
manual callbacks never inflate gateway HTTP evidence.

**Full default suite: FAIL**, reproduced after these additions at exactly
`pulse-deny-2`, with **87 preceding passing phases, 109 gateway HTTP hits and
111 MCP credential reads**. The failing phase still has zero reads and zero hits.
All original 60 phases and the 19 response-boundary phases remain in that default
run; neither existing clock file nor response-boundary file was modified.

Truncated tool output is rejected by the model parser before handoff; the
permanent regression asserts that typed failure rather than requiring a successful
completion DTO.

### Current shared-authority RED baseline

The latest expanded authorization suite reports **20 passing and 5 failing groups**
(25 total). Denial, dispatch-intent, completion, rejection and host-timestamped
guest-diagnostic expiry pulses still allow an independently approved action to be
consumed after wall-clock rollback. A ticket is not evidence of HTTP dispatch.

The latest host integration suite reports **38 passing and 5 failing groups**
(43 total). Model denial/intent/completion and streamed completion pulses do not
latch terminal state immediately. A separate audit barrier verifies that expiry
is not visible to the gateway while the authority's denial callback is blocked.
These model tests use an actual offline URLProtocol, not an external service.

The default MCP command still fails at `pulse-deny-2` after 87 passing phases.
A successfully recorded denial need not itself throw; its terminal-state and
rollback assertions remain mandatory. No shared-authority production repair is
included in this baseline. Passing isolated scopes do not make these suites pass.

**NOT RUN / held:** remaining grant-expiry pulse positions during execute and the
unreached `pulse-deny-3`, pending separate audit-clock classification. These
bounded scopes exercise selected schedules.

## Historical review and evidence scope

The literal-credential reflection correction received scoped independent review.
The baseline results above include shared-authority regressions; the shared
lifecycle interfaces are documented in [Shared run authority](shared-run-authority.md).
This bounded fixture addresses
the credential/response boundary, resource/action authorization, one-use dispatch,
audit ordering and uncertain-side-effect requirements in FINAL_SPEC §§4–5 and 7–8;
its results are scoped to the host fixture.

Binding mismatch, provider failure, disk audit ordering, response/text byte
boundaries and the independent continuation scopes above now have executed checks.
In that baseline, the remaining grant-expiry clock samples were held for
classification. Its tests cover representative barriers and ingress shapes.
Real external MCP/service accounts,
Agent/VM integration, GUI approval and lifecycle, full Streamable HTTP/SSE/session
support, generalized secret detection, and physical storage-failure testing remain
outside these local results. Evidence additions that only exercised already-existing
behavior are not represented as new behavioral RED cycles.
