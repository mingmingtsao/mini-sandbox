# Host model integration slice

## Scope and trust boundary

`HostModelGateway` composes the existing `RunAuthorizationController` (F03) and
`ModelTransport` (F04). It is a package-internal, trusted-host coordinator, not a
second standalone policy engine. It privately constructs and owns the F03
controller. Run handles, proposals and approvals cannot be decoded or constructed
by a guest; handles are checked by object identity against this gateway's state.

**There is no guest listener, guest RPC decoder, VM integration, or F10 approval UI
wiring in this increment.** An eventual authenticated ingress must map a host-owned
run to these APIs rather than accept a serialized handle. The fixture checks do
not establish guest isolation or live external-service behavior.

The trusted host supplies a connection registry. Each connection binds its ID,
host account ID, account-binding version, route version, fixed protocol/model,
and account-specific credential provider. The host must bind that provider to the
specified account correctly. Requests cannot supply URLs, authentication headers,
or a different protocol/model. The transport retains its fixed endpoints and
redirect rejection. Configuration injection is a host testing/deployment seam,
not guest input.

## Lifecycle

1. `install(grant:)` creates an opaque handle; installing or decoding a grant does
   not dispatch anything.
2. `propose` requires the exact `model / deepseek-flash / complete` or
   `model / deepseek-flash / stream` scope on the requested connection. Explicit
   deny wins; unknown connections, services, operations and resources fail closed.
3. The canonical sorted-JSON envelope binds schema version, run ID/epoch,
   connection/account IDs and versions, full validated request, and streaming
   mode. F03 binds those bytes and the grant/schema digests into its pending
   action. The gateway admits no caller-supplied raw canonical JSON.
4. Only `hostApprove` creates the one-use approval. There is no low-risk
   auto-approval path. `hostDeny` delegates to F03's audited denial lifecycle.
   Early gateway rejections (including scope/policy explicit deny, invalid
   connection/protocol/handle, message bounds and observed grant expiry) occur
   before F03 and are **not F03-audited**. An explicit host `hostDeny` decision
   is audited by F03 as `explicit-deny`; these are distinct paths.
5. `execute` consumes the F03 approval, which synchronously appends dispatch intent
   through the supplied audit sink. Production must supply a durable sink such as
   `JSONLAuditSink`; an arbitrary in-memory sink does not itself provide durability.
6. Only after successful intent persistence does the gateway reconstruct the
   actual request from `DispatchTicket.approvedRequest`, access the bound
   credential provider, and start the actual transport operation. It does not
   accept replacement request data or a replacement streaming mode at execution.
7. F03 completion is attempted exactly once per issued ticket. Nonstream success
   and the streaming success-final marker are withheld until that append succeeds.

Canonical proposals are bounded by the smaller of the grant's `messageBytes` and
F03's 65,536-byte action-binding cap. This is an ingress/canonical-envelope limit;
there is no guest output framing in this slice. Run concurrency is reserved before
awaiting consumption and capped by the smaller of the grant's limit and the
transport's four-operation cap. Existing validated request, encoded body,
response, SSE-line, timeout and redirect bounds remain in force.

## Actual dispatch linearization

`ModelTransport.prepare` synchronously creates a **suspended** `URLSessionDataTask`
and a cancellable `ModelPreparedOperation`. Preparation is not dispatch and must
not be used before authorization/intent persistence, since it accesses credentials.
`ModelPreparedOperation.start()` is one-shot and calls `URLSessionDataTask.resume()`
synchronously before returning. It does not enqueue a Swift `Task` to start later.
The transport's existing async completion and stream methods also use this real
operation API; their old checks are retained unchanged.

The gateway rechecks run/generation and registry state on return from authorization
and stream/completion awaits before taking a success-affecting action. Its final
liveness check and `operation.start()` run in the same actor turn, with **no await
between them**. STOP first marks the gateway run revoked and advances its
generation, then cancels registered operations, before awaiting F03 STOP. Registry
revocation/update similarly changes local state before awaiting F03 reconciliation.
Thus, when STOP/revocation has linearized before resume, late audit/approval work
cannot start a new task. If resume linearized first, cancellation is best-effort.
Calling STOP does not undo already-started upstream effects or rewind bytes sent.

A synchronous credential provider can delay this actor turn; STOP cannot preempt a
synchronous provider already running. Task resume, not caller invocation time or
physical packet transmission, is the start linearization point. The gateway never
returns a ticket as evidence that network dispatch has occurred.

The sole gateway clock reader, `validatedRunTime`, checks terminal run expiry
first (synchronously latching revocation/cancellation), then the not-yet-valid
boundary, then an optional action start deadline, all against **one sample**.
Not-yet-valid and action-only expiry are nonterminal while the run has not expired.
The action's F03 deadline is checked after consumption/before credential
preparation and again after preparation immediately before resume. An intent
append advancing the injected clock by 301 seconds produces zero credential
reads and zero starts; a credential provider advancing it by 301 seconds produces
one authorized preparation read but zero starts (grant TTL is 600 seconds).
Both issued tickets are completed once as `.failed` / gateway `.notStarted`.
Action expiry is **not** applied to in-flight chunks or completion: an on-time
start whose completion audit crosses the action deadline still succeeds while
the grant remains live.

Observed grant expiry synchronously latches local revocation and cancels registered
operations before any reconciliation await. All proposal/approval/denial/execution
validation paths await F03 STOP reconciliation, including initial validation
failures; F03 `grantExpired`/`runRevoked` errors also reconcile local state. The
proposal scope-check timestamp comes from the same validated primitive before
applying scope-decision priority, so an explicit deny cannot hide expiry on a
second clock sample. Ordinary scope denial before expiry leaves the run live and
previous valid approvals usable. STOP preserves issued tickets for their one
completion. A later host-clock rollback cannot revive an observed-expired
approval. This is host-clock fault injection, not a claim that a guest can control
the host clock.

### Temporal boundary inventory

Before centralization, the gateway read its clock independently in `live`, the
proposal scope check, and `validateStartDeadline`. The last reader checked only
the action deadline and could misclassify observed run expiry. Now **all gateway
clock reads and run/action comparisons** pass through `validatedRunTime`:

| Boundary | Fresh validation and disposition |
| --- | --- |
| `install` | F03 validates installation time; no gateway dispatch permission is created. F03 retains its own injected clock and is unchanged. |
| `propose` | `live` checks run time/registry; a fresh validated sample is passed to scope decision (explicit-deny priority within a live grant); validation repeats after awaited F03 proposal. |
| `hostApprove` / `hostDeny` | Run/generation/registry validation before and after each awaited F03 operation. |
| `execute` admission / consume | Validate before reservation, after awaited consume/intent audit, and when resolving the decoded envelope connection. |
| Pre-credential / post-preparation start gates | Each takes one fresh sample for run validity and action deadline; post-preparation also repeats generation/registry/cancellation checks. No await from final check to actual synchronous resume. |
| In-flight chunks / EOF / completion audit | Fresh run/generation/registry checks after chunk awaits, after iteration, and after awaited durable completion; no action deadline restriction on legitimate in-flight completion. |
| Error reconciliation | Local expiry latches before suspension. F03 `grantExpired`, `runRevoked`, or `auditFailed` also latch via `handleError`; revoked runs await F03 STOP. Ordinary denials and action-only expiry do not revoke. Issued tickets retain one completion attempt, `.failed` before start or `.unknown` after start; audit failure remains `.auditFailed`. |
| STOP / registry updates / observation | STOP revokes/cancels before await; registry changes invalidate/cancel before reconciliation. They read no clock. `isRevoked` is a passive getter and cannot repair state. |

The default `Date()` closure supplies the injected clock; it is not a separate
validation path. Scope decision uses the already validated timestamp, never a
second hidden sample. Failure cleanup introduces no new dispatch or success path.

## Outcome semantics

- `execute` returns `ModelCompletion`, not a ticket. Streaming uses its ordered
  callback for provisional text and exactly one audited success final.
- An issued ticket blocked before resume is completed as F03 `.failed` and the
  gateway reports `.notStarted`. F03 does not allow `.notDispatched` as a completion
  outcome; its intent already records `.notDispatched`.
- Cancellation, revocation or connection failure after resume reports
  `.outcomeUnknown` and normally records `.unknown`. There is no automatic retry.
- If upstream completion was already observed and recorded before STOP wins the
  delivery race, its audit remains `.completed`, but the gateway suppresses late
  success delivery and reports `.outcomeUnknown`. It never writes a second
  compensating completion.
- An audit append failure reports `.auditFailed`, revokes the gateway run, and
  cancels its other operations. A failed completion append is not retried or
  represented as a successfully persisted record. Provisional stream text may
  already have been delivered, but no success final follows the failure.
- Audit fields and errors contain no canonical body, prompt, credential, provider
  response body, or raw network error. Fixed resource/operation labels are used.

## Verification

Default checks are offline transport fixtures. The opt-in real host smoke is:

```sh
swift run HostIntegrationChecks --live
```

It requires `TEST_DEEPSEEK_KEY` already set only in the host test process. It does
not read `.env`, use Keychain, expose a guest listener or simulate native UI
consent. It sends a fixed harmless prompt to the existing fixed provider routes;
normal checks never access this credential or the live service. Missing test key
exits 2 (BLOCKED), invalid CLI mode exits 64, failed live assertions exit 1.
Results expose only case labels/counts, not credentials, prompts or response text.


`HostIntegrationChecks` exercises real Swift F03/F04 integration against a controlled
`URLProtocol` fixture, counting requests at `startLoading`. It covers actual
approved dispatch, the independently permissive direct upstream baseline,
service/resource/operation and connection/handle denial, explicit deny, replay and
concurrent consume, STOP while F03 intent append is blocked, late approval,
connection revocation/update, cancellation and network failure after start,
intent/completion audit failure, ordered streaming and audit-gated final delivery,
caller request mutation, grant limits, expiry, and STOP during completion audit.
One check uses the actual synchronous JSONL sink and verifies the intent is already
readable from disk when the fixture receives the request.

The known Keychain authorization environment block remains separate from fixture
success. VM/Agent/F10 integration is not claimed. The existing controller retains
installed run state for its lifetime; long-lived host run retirement/recovery and
crash reconciliation are not added here.

Review regression evidence (all prior checks retained):

- GATEWAY-01 RED: **23 PASS, 3 FAIL, total 26**, exit **1** (both delayed
  start paths and capacity-reuse regression). GREEN: **26 PASS, 0 FAIL**, exit **0**.
- GATEWAY-02 RED: **26 PASS, 5 FAIL, total 31**, exit **1** (expiry observed
  at propose/approve/deny/execute and outstanding completion). GREEN:
  **31 PASS, 0 FAIL, total 31**, exit **0**.
- Model transport RED: **28 PASS, 1 FAIL, 1 BLOCKED, total 30**, exit **1**;
  cancelled hanging completion incorrectly returned success **50/50**. GREEN:
  **29 PASS, 0 FAIL, 1 BLOCKED, total 30**, exit **2**, with actual cancelled
  `Task.result` **50/50**. Keychain remains BLOCKED (`-60008`).
- Prepared cancel-before-start, deinit-before-start, repeated cancel/deinit and
  exact-once limiter release pass: four held reservations, fifth `busy`, after
  repeated cycles. Valid empty completed text/streams remain accepted. Gateway
  capacity is reused after pre-start failure and eight sequential successes.
- GATEWAY-03 (second-clock-sample expiry) RED on unchanged production code:
  **32 PASS, 2 FAIL, total 34**, exit **1**. Both the allowed-scope and explicit-deny
  crossings left `isRevoked` false; rollback dispatched the older approval with
  **1 credential read / 1 fixture hit** each. GREEN: **34 PASS, 0 FAIL, total 34**,
  exit **0**; both crossings latch immediately and rollback causes **0 credential
  reads / 0 fixture hits**. The positive control covers ordinary and explicit
  scope denial before expiry: the run stays live and its older approval succeeds.
- Current gateway/prepared-transport live smoke, rerun after centralized-time
  validation on 2026-10-24: **4/4 PASS** (OpenAI and Anthropic, completion and
  streaming), using trusted host test grants and an actual JSONL sink. Each
  success has its intent/completion audit pair; streaming success-final follows
  durable completion. The audit omits the test credential and prompt. This
  verifies the current candidate's positive host path, not its adversarial
  security cases, and remains distinct from the historical PR #7 transport-only
  result. Keychain, VM, Agent and UI integrations are not established by it.
- GATEWAY-04 centralized-time repair RED on unchanged production code:
  **34 PASS, 2 FAIL, total 36**, exit **1**. Both deadline-only samples observed
  exactly `grant.expiresAt` yet immediately left revocation false. After rollback,
  each older approval added **1 credential read / 1 fixture hit**. The post-prepare
  case separately had **1 prior credential read / 0 prior hits**; pre-credential
  had **0 / 0**. Adding both not-yet-valid start-gate regressions yielded
  **34 PASS, 4 FAIL, total 38**, exit **1** (old code dispatched at those samples).
  GREEN: **38 PASS, 0 FAIL, total 38**, exit **0**. Expiry latches before rollback,
  which adds **0 reads / 0 hits** at both gates; each issued unstarted ticket is
  completed once as `.failed`. Not-yet-valid rejection remains nonterminal and
  the older approval works once time is valid again. Action-only expiry explicitly
  leaves the run live; legitimate completion beyond the action deadline still passes.
- Current offline rerun: Host integration **38/38**, authorization **17/17**,
  contracts **7/7**, and `swift build --product MiniSandbox` all exit **0**.
  Model transport remains **29 PASS / 0 FAIL / 1 BLOCKED / 30**, exit **2**, not
  a full-suite PASS; direct completion cancellation is **50/50**.
  API boundary **4/4** and packaging **7/7** also passed after centralization.
