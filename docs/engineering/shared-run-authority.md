# Shared run authority increment

## Actual integration API

`Sources/SandboxWorkbench/RunComposition.swift` is the App composition root.
`ApplicationDelegate` retains it. `RunComposition.install(_:)` installs a grant
once in F03, then injects the same controller and `HostRunHandle` into the
workbench, model gateway and MCP gateway. Its `diagnosticSession(owner:run:)`
passes that same handle to the VM protocol session; it does not launch a VM.
Connection registries are empty at App startup until trusted configuration is
provided. This is not an App→Agent end-to-end completion claim.

- `RunAuthorizationController(auditSink:now:monotonic:)`: F03 action/ticket
  ledger. Production monotonic time uses `ContinuousClock`; tests can inject a
  trusted duration source. `install(grant:)` creates the run handle exactly once.
- `HostRunHandle.lifecycle`: the shared **reference**, not a reconstructed UUID.
  `validateAttachment(handle:grant:)` rejects handles from another controller or
  a different grant. The VM also verifies the handle's bound grant digest.
- `RunLifecycle.observeAndReduce(reason:)`: samples trusted wall/monotonic time
  outside its mutex, then synchronously reduces state and returns immutable
  `wallTime`, `effectiveTime`, `sequence`, `generation`, and `status`.
- `RunLifecycle.terminate(_:)`: irreversible `active` → `expired`, `revoked`,
  `stopped`, or `faulted`; advances generation only once. No provider, emitter,
  audit append, filesystem operation, or cancellation runs under its lock.
- `invalidateConnection(_:)` / `permitsConnection(_:)`: shared connection
  invalidation scoped to bound runs. It does not stop unrelated runs.
- `HostModelGateway` / `HostMCPGateway` initializers accept `authority:`;
  `install(grant:authorityHandle:)` attaches rather than reinstalling.
  `lifecycle(handle:)` exposes identity to trusted composition/tests.
- `WorkbenchModel(audit:authority:)` and
  `installTrustedGrant(_:authorityHandle:)`: UI caches are projections. Stop and
  Close establish the shared terminal synchronously before their first await,
  even if F03 is blocked in a synchronous audit append.
- `VMDiagnosticSession(...authorityHandle:installedGrant:)`: host session hook;
  checks the shared authority at protocol access and after reply-intent audit.

A current-status getter is a projection, **not** a fresh execution permit.
A snapshot is an observation, **not** a transferable capability.

## Temporal and audit semantics

The monotonic deadline is computed once at installation. Wall high-water never
moves backward; either wall expiry (including exact equality) or the monotonic
deadline latches expiry. Subsequent rollback cannot revive the run or extend its
unsent action permissions. Guest diagnostic *timestamps* are sampled by the
host through the same reducer; guest-supplied timestamps are never authoritative.

F03 host events, rejection and guest diagnostics use immutable observations.
Audit append does not recursively re-observe time. Sequence numbers identify
observations per run; they are not a promise that concurrent audit appends reach
disk in the same order. Audit failure faults the run; ordinary expiry is not
reported as `auditFailed`.

The 300-second action lifetime is a **start deadline**, not an in-flight request
TTL. Issued tickets remain one-shot result bookkeeping after terminal state;
they do not authorize new work or delivery. Gateway checks after audit and
credential preparation consult the shared reference. Existing completion,
capacity, and decoded-credential reflection checks are retained.

## Approval-sheet Stop reachability

The parent and modal approval sheet reuse one `stopControl(runID:)`. Inside the
sheet it is a sibling of, not a child of, the ordinary busy-disabled button row.
Return still selects Deny; Escape still selects Cancel / deny. Both use the same
deny-only dismissal route. Stop uses the same model authority and clears its
presentation before awaiting audit cleanup. No additional permission ledger or
clock check is introduced.

`WorkbenchApprovalController` owns presentation only. Identity-checked clearing
prevents a stale completion from dismissing a different action; native dismissal
retains default-deny and does not revoke an already-approved capability.
`SharedAuthorityChecks` includes a permanent structural binding regression that
failed on the parent-only Stop, plus the compiled presentation/controller route:
a presented action's real denial audit is held while ordinary controls are busy,
then Stop establishes shared terminal state and clears pending/presentation before
release. Old model/MCP approvals read no credentials; VM protocol access is denied;
denial and issued-ticket completion remain exactly once. Cleanup task errors are
propagated. These are source-binding and compiled-route checks, **not rendered
GUI click, keyboard, or accessibility evidence**.

## Remaining safety boundary (not release-ready)

This increment does **not** serialize the final shared check with the concrete
URLSession `resume()` across executors. Nor does it replace arbitrary streaming
callbacks with a controlled receiver that rechecks at actual business acceptance.
P2 must supply those concrete start/receiver boundaries, including run generation,
connection invalidation, action start deadline, and cancellation. A pre-committed
delivery ticket followed by a later unchecked callback is not sufficient.
Raw OS completions may still arrive for cleanup; they must not become business
success after terminal state. Shared Stop prevents later admissions, but proactive
cancellation of every already-running transport from the UI and VM socket-write
acceptance still require integration work. No full safety or App/Agent PASS is
claimed.

## Executable evidence entrypoints

- `swift run SharedAuthorityChecks`: actual pointer identity across the App
  composition; UI Stop while the F03 audit callback is held; VM access and
  foreign-handle rejection; independent runs/connections; wall rollback,
  equality, monotonic-only expiry/simulated sleep; old-controller handles;
  independently approved model and MCP actions denied after shared terminal.
- `swift run AuthorizationChecks`: retains all eight shared-expiry observation
  paths, including the former denial/intent/completion/rejection/diagnostic REDs.
- `swift run HostIntegrationChecks`: retains all five shared-expiry regressions,
  including terminal visibility before the audit call returns and measured
  dispatch/completion audit pulse positions.
- `swift run MCPGatewayChecks` is a driver child, not a standalone suite. Build
  it, then run `python3 Tests/MCPIntegrationTests/test_loopback.py` and separately
  `python3 Tests/MCPIntegrationTests/test_loopback.py --scope independent`.
  Both drivers compare exact named phase sets and preserve R1 reflection cases.
- Also run `swift build`, `WorkbenchChecks`, `StructuredModelChecks`, `VMChecks`,
  `WorkspaceChecks`, and `ContractChecks`. `ModelTransportChecks` default mode
  additionally attempts isolated Keychain CRUD; it is not an offline-only suite.

`Tests/SharedClockSupport/SharedHostClock.swift` is the common deterministic clock
fixture for F03, model, MCP, and cross-component checks. No live provider, Keychain
operation, or VM launch is needed for this increment's checks.
