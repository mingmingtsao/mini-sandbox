# Native authorization workbench — first F10 increment

This is a native SwiftUI presentation of the F03 `RunAuthorizationController`, not a VM implementation. The normal application starts with no grants, proposals, approvals or sample activity. It explicitly reports that the runtime producer / VM is not connected. The Environment tab and `--diagnostics-json` retain the foundation environment check.

## Trusted host integration

`WorkbenchModel` is `@MainActor` and owns its real authorization controller. All authority-changing ingress is an in-process trusted-host API; none is a guest JSON endpoint. The controller's `HostRunHandle` remains private to the model.

- `installTrustedGrant(_:)` installs the immutable `RunGrant` with F03 before publishing its snapshot.
- `proposeTrustedAction(binding:display:)` calls F03 `propose` and publishes the returned immutable `PendingAction`. Service is resolved from the installed grant's connection and scope, not a guest service label.
- `approveOnce(_:)` invokes `hostApprove` with the captured action ID and nonce, returns the real `ApprovedAction`, and retains it in `approvedActions` for trusted-host integration. The view never calls `consume` or performs external execution.
- `consumeForTrustedHost(runID:approved:)` explicitly forwards a capability to F03 `consume`; only a future trusted broker should call it. The returned `DispatchTicket` contains the original approved bytes. Ticket creation is not external execution success.
- `completeForTrustedHost(runID:ticket:outcome:)` records the actual broker outcome through F03. Do not report completion without actual execution evidence.
- `deny(_:)`, `dismiss(_:)`, and `expirePending()` retire pending authority through the real controller. Timeout denies an expired pending action; expired grants revoke the whole run. F03 independently enforces expiry at approval/consumption. If F03 already cleaned up an expired proposal (for example, while proposing another action), its `actionNotPending` response removes only the stale pending snapshot. Direct `deny` still throws that semantic failure; dismissal recognizes it without a repeated error. No extra denial audit is fabricated. This response does not establish that an approved capability was revoked: real `approvedActions` remain intact. Other errors, including `auditFailed` and `invalidHandle`, retain their existing handling.
- `revokeConnection(runID:connectionID:)` invalidates the controller's connection and corresponding displayed proposals/approvals.
- `stop(runID:)` awaits controller revocation before publishing stopped. `close()` blocks ingress, drains in-flight model work, revokes all installed handles, and returns only afterward. Application termination uses AppKit's deferred termination/reply handshake; the window close button routes through that handshake.
- `recordGuestDiagnostic` has no origin or control-handle parameter. It always uses F03's diagnostic ingress.

Use this model as the single lifecycle writer. It does not discover unrelated controllers or accept externally constructed guest control handles. Concurrent ordinary mutations receive `WorkbenchError.busy`; callers should coordinate/retry rather than treating that as a successful operation.

## Native approval and activity

Review opens a native sheet displaying the immutable run, action, connection, resolved service, resource, operation, display snapshot and expiry. Return defaults to Deny; Escape is Cancel / deny. Sheet dismissal also invokes denial. Approve once is explicit and never a default keyboard action. Late responses are checked by F03 and refresh the published state. Content is native `Text(verbatim:)`, not HTML, Markdown execution, a browser, or a terminal.

Grant scopes are the actual immutable installed snapshot and are explicitly not a claim that a revoked connection is currently available. Host-enforcement activity and guest diagnostics are separate sections. The displayed trusted denial count uses `SecurityEvent.isHostRejection` only, over the displayed event window.

## Durable audit

The default app creates a new UUID-named JSONL file under Application Support / MiniSandbox / Audit. The directory is created with mode 0700; the file uses exclusive creation, no-follow, append-only mode 0600. A synchronized `workbenchStarted` lifecycle record verifies a real startup write before authority becomes available. This record is not a run, grant, diagnostic, or host enforcement event.

Each subsequent `SecurityEvent` is encoded and synchronized before entering the bounded 200-event in-memory activity cache. There is no in-memory fallback if disk creation or writing fails. Startup failure leaves the controller unavailable and displays an error. Later audit failures disable authority and revoke installed runs. The disk retains the full session event stream; the cache is not a complete-history counter.

## Verification boundary

`WorkbenchChecks` uses actual F03 controllers, temporary JSONL files and explicitly synthetic test-only grants. It checks empty startup, snapshots, deny/dismiss, exact approved bytes, no auto-consumption, late rejection, timeout, connection revocation, awaited close, startup audit creation/write failure, runtime write failure, guest classification, bounded durable activity and side-effect-free view construction. Write failures are real OS failures induced only inside the check process by a temporary file-size resource limit; the prior limit and signal handler are restored. These are executable model checks, not GUI-interaction certification.

The already-retired regression was observed RED before the model fix: A was proposed, the clock advanced 301 seconds with the grant still live, and proposing B triggered F03 cleanup of A; timeout left A displayed. The checks now assert A absent and B present immediately after timeout/dismiss/direct deny, before any late approval can mask stale state. They also verify unchanged audit events, repeated dismissal, truthful direct-deny failure, and preservation and successful consumption of a real approval after a stale deny.

Verified on Apple Silicon / macOS 26.6.2 / Swift 6.3.3: `swift run WorkbenchChecks` passed 53 assertions; `AuthorizationChecks` passed 17 groups; `ContractChecks` passed 7 groups; foundation API and packaging checks passed 4 and 7 tests respectively. The Release App was packaged, locally ad-hoc signed and verified, and its `--diagnostics-json` command succeeded. Native launch produced an on-screen window belonging to that packaged executable; an explicit quit request to that exact process was accepted and the process exited. This native lifecycle check used only the empty default application.

GUI button/keyboard/sheet interactions are **BLOCKED** by desktop access permissions. Window-scoped image capture also failed, so visual layout has not been certified. Manual QA still must exercise Review, Return, Escape, sheet dismissal, Stop, window close and Quit with trusted-host test ingress. The default app intentionally has no demo buttons or synthetic-run switch. This increment does not establish VM execution, broker execution, G1/U01, or full F10 acceptance.
