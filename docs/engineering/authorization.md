# Host authorization lifecycle

## Authority and binding

`RunAuthorizationController` is the host-side authority for this in-memory approval lifecycle. A trusted host entry point installs a validated `RunGrant` and receives a `HostRunHandle` created inside the host module. The handle has no public initializer; a guest-reported `runID` cannot authenticate a proposal.

A proposal must carry a host-validated `ActionBinding`. The controller checks the handle, run, epoch, grant digest, connection identity and live account/route versions, then maps the binding to exactly one granted `ResourceScope`. Explicit denies and revoked connections reject the proposal. Adapter validation and resource resolution remain the trusted caller's responsibility. The pending action captures the original canonical `Data`; approval and ticket issuance use those bytes, not a later caller payload. A check mutates the caller's `Data` after proposal and verifies the ticket still contains the original bytes.

The grant digest hashes an exhaustive canonical DTO, not `RunGrant`'s unordered Codable sets. Connections are sorted by UUID string; each scope set and `explicitDenies` are sorted by the full `(service, resource, operation)` tuple. Sorted-key JSON includes all grant, connection, scope, and resource-limit fields. Multi-element reconstructions, connection reordering, and Codable round trips produce the same digest; changing individual fields changes it. The DTO and its field-coverage checks must be updated when the foundation contract gains fields.

## Approval, revocation, and dispatch intent

Host approval checks the action ID, nonce, grant lifetime, and live connection before returning an immutable one-use approval. Consumption rechecks the live handle, grant lifetime, connection, original action binding, and scope. The actor retires the approval before returning a `DispatchTicket`, so concurrent consumers have one winner. A host dispatch-intent event must be appended successfully before a ticket is returned; an audit failure revokes the run and returns no ticket.

Connection revocation is terminal for that installed run. `updateConnection` cannot clear revocation or decrease either account-binding or route version. An unchanged update is harmless. Any accepted version change immediately invalidates that connection's pending and approved actions; later rollback is rejected and cannot revive them. The installed grant is immutable, so using changed versions requires a fresh grant/run rather than updating an old approval. Other connections and already-issued tickets are not canceled by this invalidation.

`stop` and `close` revoke the run, advance its epoch once, discard pending/approved requests, and block new proposals, approvals, and tickets. They preserve completion recording for already-issued tickets. Completion is one-shot as `completed`, `failed`, or `unknown`, including after stop or grant expiry. A completion audit failure consumes the recording attempt and revokes the run; it is not automatically retried.

**A `DispatchTicket` is an intent, not an external dispatch.** Actor serialization makes ticket issuance atomic relative to stop, but there is no atomic handoff to a Broker or remote service here. Stop blocks new tickets; it does not withdraw an already-issued intent, prove that external dispatch has not started, or cancel remote effects. This controller performs no external dispatch and no automatic retry, including for `unknown` outcomes.

## Bounds and retained-state policy

These limits are per installed run, not lifetime action quotas:

| State | Bound / retention |
| --- | --- |
| Pending plus approved actions | 32 combined; a 33rd proposal returns `pendingLimit`. |
| Canonical request bytes retained by the controller | At most 65,536 per active action (foundation contract), or 2,097,152 bytes / 2 MiB per run, excluding object overhead and caller-held values. |
| Display snapshot | At most 4,096 UTF-8 bytes per active action. |
| Issued tickets awaiting completion | 32 metadata-only records; a further consume returns `pendingLimit` without consuming its approval. Completion releases a slot; no unfinished ticket is evicted. |
| Terminal action history | Last 64 retired action IDs and error reasons, with no request bytes or display snapshots. |
| Completion history | Last 64 completed ticket IDs, with no request bytes. |

Denial, consumption, connection invalidation, and run revocation remove the active request record. Expiry is cleaned up lazily on proposal, approval, or consumption; there is no timer, so an idle run can retain expired requests within the same bound until one of those calls or stop. Completion records retain only action ID, operation, and resource summary, so old unfinished tickets can still complete after action-history eviction and stop. Terminal history is FIFO-bounded: recent replays receive specific errors; an evicted action/ticket remains unauthorized and returns `actionNotPending` or `ticketInvalid`. Eviction never re-creates authority. Checks exercise more than 64 denials/completions and repeated expiry batches without a permanent action cap.

**Run states themselves are retained for the lifetime of the controller, including stopped/expired runs.** This preserves duplicate-run rejection and late completion metadata. There is no global run-count bound or run-eviction API yet; aggregate grant/handle/history storage can grow with installed runs. Stopped runs retain no controller-owned canonical request bodies. An idle, un-stopped run can retain the bounded active bodies described above. Caller-held `PendingAction`, `ApprovedAction`, and `DispatchTicket` values have caller-controlled lifetimes; dropping controller references is not a secure-memory-erasure guarantee. The JSONL audit file is append-only in this implementation and has no rotation or total-size limit.

## Exact event inventory and data handling

The controller currently attempts only these event categories (successful append is required where noted):

| Trigger | Origin / decision | Reason / outcome |
| --- | --- | --- |
| Selected proposal rejections | `hostEnforcement` / `deny` | `wrong-run`, `wrong-epoch`, `grant-binding-mismatch`, `connection-not-granted`, `resource-not-granted`, `explicit-deny`, or `scope-denied`; `notDispatched`; no action ID. |
| Explicit host `deny` of a pending action | `hostEnforcement` / `deny` | `explicit-deny`; `notDispatched`; action ID included. |
| Successful ticket issuance | `hostEnforcement` / `allow` | `dispatch-intent`; `notDispatched`; append must succeed before returning the ticket. |
| Completion recording attempt | `hostEnforcement` / `allow` | `dispatch-completion`; caller-reported `completed`, `failed`, or `unknown`. This is not independent evidence of a remote result. |
| Valid `recordGuestDiagnostic` input | `guestDiagnostic` / `observe` | Caller-supplied message; `notDispatched`; no action ID. |

There are no separate events for installation, accepted proposals, host approval, stop/close, connection revocation/update, expiry cleanup, capacity rejection, invalid handles, nonce mismatch, or replay rejection. Live-connection rejection in proposal/approval/consume is also not separately audited. This is not a complete lifecycle audit inventory. Sequence numbers are allocated for event construction attempts and may have gaps on validation/append failures. An audit append failure revokes the affected installed run; a diagnostic for an unknown run has no installed run to revoke.

`SecurityEvent` bounds operation, resource summary, and reason to 512 UTF-8 bytes each and rejects empty/control-character text. These are validation bounds, **not redaction**. The controller does not automatically log canonical request bodies or obtain/log credentials. However, guest diagnostic fields are stored as supplied after validation, and host resource/operation summaries are supplied through bindings. Text can therefore contain sensitive strings if callers put them there. There is no proven blanket secret/token redaction and no guarantee that an event can never contain a token. Diagnostic callers cannot choose their event origin; guest claims remain `guestDiagnostic` / `observe` and never authenticate control operations.

`JSONLAuditSink` creates an exclusive mode `0600` file with no final-component symlink following. Each event is JSON encoded as one line, synchronously written, and synchronized with `FileHandle`. Errors fail closed for the affected run, but a failed write/synchronize can leave partial or already-written bytes. There is no transactional audit rollback, tamper-proof guarantee, or protection from same-UID file modification.

## Verification boundary

The executable `AuthorizationChecks` and foundation `ContractChecks` exercise this local authorization seam without XCTest. Their recorded scope lists VM integration, Broker integration/atomic external dispatch, and S16 acceptance as `NOT_RUN`; external dispatch uses the separate gateway and final-effect interfaces.
