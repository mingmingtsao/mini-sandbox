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

Use the application composition as the owner of the existing F03 lifecycle references. The workbench does not discover unrelated controllers or accept externally constructed guest control handles. Concurrent ordinary mutations receive `WorkbenchError.busy`; callers should coordinate/retry rather than treating that as a successful operation.

## Native approval and activity

Review opens a native sheet displaying the immutable run, action, connection, resolved service, resource, operation, display snapshot and expiry. Return defaults to Deny; Escape is Cancel / deny. Sheet dismissal also invokes denial. Approve once is explicit and never a default keyboard action. Late responses are checked by F03 and refresh the published state. Content is native `Text(verbatim:)`, not HTML, Markdown execution, a browser, or a terminal.

Grant scopes are the actual immutable installed snapshot and are explicitly not a claim that a revoked connection is currently available. Host-enforcement activity and guest diagnostics are separate sections. The displayed trusted denial count uses `SecurityEvent.isHostRejection` only, over the displayed event window.

## Durable audit

The default app creates a new UUID-named JSONL file under Application Support / MiniSandbox / Audit. The directory is created with mode 0700; the file uses exclusive creation, no-follow, append-only mode 0600. A synchronized `workbenchStarted` lifecycle record verifies a real startup write before authority becomes available. This record is not a run, grant, diagnostic, or host enforcement event.

Each subsequent `SecurityEvent` is encoded and synchronized before entering the bounded 200-event in-memory activity cache. There is no in-memory fallback if disk creation or writing fails. Startup failure leaves the controller unavailable and displays an error. Later audit failures disable authority and revoke installed runs. The disk retains the full session event stream; the cache is not a complete-history counter.

## Fixed-model connection settings — partial increment

The inline Workbench panel supports **DeepSeek flash with the Anthropic protocol only**. It has a native `SecureField` and explicit Save, Check stored credential, and Delete actions. No credential is preloaded into the field, published in observable state, written to a plaintext fallback, or sent to a provider by these actions. Input is cleared before starting an action, when the panel disappears, and on close. Swift string copies used by an in-flight operation are not a secure-memory-zeroization guarantee.

`RunComposition` owns this controller alongside the existing single F03 authority, Workbench and MCP gateway. Storage is the existing noninteractive host Keychain provider. Synchronous Keychain work runs in detached tasks, outside MainActor and the shared lifecycle fence. A busy settings operation disables only settings controls; existing Stop and approval-sheet Stop bindings are unchanged. Environment inspection is also explicit and performs its query off MainActor.

Configuration is **next-run-only**, not a live account swap:

1. Clear routing availability and synchronously terminalize installed model-bound runs, including their displayed pending/approved state.
2. Detach the old model gateway and permanently revoke its connection registry, awaiting revocation of every attachment before any storage operation. No `updateConnection` follows revocation.
3. Perform the requested storage operation. Failure leaves routing unavailable; no previous configuration is restored.
4. Only a successful Save or a successful explicit Check that finds a credential publishes a new typed `HostModelConnection` and future-run gateway. Account and route versions strictly advance, including across failed attempts. Fresh composition identities prevent old grants from matching after restart.

There is no added grant ledger or automatic grant/approval/dispatch. Trusted integration must use `RunComposition.install` and the `InstalledRun.modelGateway` paired with its model handle. Every suspension during installation rechecks the configuration generation; a concurrently retired installation cannot escape as a live run. Stop/close still use the shared lifecycle. Close immediately disables settings and ignores late storage completion without waiting for Keychain; an OS write already in progress may finish in storage after close, but cannot publish routing. Next launch starts unavailable until explicit Check or Save.

`WorkbenchChecks --connection-settings-only` runs the real controller/composition with injected synthetic blocking/failing storage. The default Workbench suite retains its original 53 assertions and then runs the settings checks. These cover no preload/approval, pre-storage retirement, busy Stop, old-version and retired-registry denial, fixed typed binding, missing/invalid input, close/late completion, and source bindings. They do not certify rendered clicks.

The packaged executable offers one opt-in noninteractive diagnostic:

```sh
dist/MiniSandbox.app/Contents/MacOS/MiniSandbox --keychain-canary-selfcheck
```

It accepts no credential input. It generates a fresh random service/account and synthetic values in memory; verifies add/read/update/delete; and cleans up only that owned item. It requires the packaged bundle identity, reports booleans/static verdicts and an OSStatus, and returns exit 2 for `BLOCKED` (not PASS). It never reads or modifies the production/default credential item. Actual OS CRUD and rendered GUI acceptance must be recorded separately from injected-storage checks. This is not VM/Agent readiness, full F10/P7 acceptance, or a release approval.

## Verification boundary

### Composition-owned shutdown

`RunComposition.beginClose()` synchronously seals its ownership registry before
terminating every registered F03 lifecycle. AppKit calls this method directly in
its termination callback, before creating the cleanup task. Workbench and settings
close routes also enter that same seal. Repeated close shares the workbench's
cleanup task; a successful termination reply requires pending attachment and
gateway-operation registrations to drain and authority cleanup to finish.

The registry owns identities, not a new lifecycle or execution permit. Pending
intake bookkeeping is distinct from ownership: a handle is retained only after a
synchronous immutable provenance check against this composition's F03 authority.
This does not replace the existing actor-isolated attachment validation. Genuine
same-authority handles remain close-owned **before** that validation can suspend,
including rejected grant bindings. Foreign handles are rejected without being
retained or terminalized. Retirement uses the handle's immutable installed grant,
never the caller's unvalidated grant: an invalid claim can neither hide a real
connection nor invent one. No new execution/delivery permit is returned, and F03
clock, terminal and authorization logic is unchanged. Failed foreign intake no
longer poisons repeated close; an actual cleanup failure still returns false.

The in-process `diagnosticSession(owner:run:)` hook authenticates the handle's
immutable same-authority provenance before observing or retaining its lifecycle.
An equal run ID or even an identical grant installed under another authority is
not ownership. The existing installed-grant/digest validation remains intact;
no new lifecycle, run-ID lookup or execution permit is introduced. Rejection
creates no session and changes neither source authorization nor either audit.
`WorkbenchChecks --composition-diagnostic-only` covers distinct-ID and equal-ID
foreign intake, source diagnostic usability after rejection and repeated receiving
close, audit isolation, genuine local close/revoke and installed-grant mismatch.
Both foreign-intake cases were witnessed RED before the provenance check; the
three local/validation controls first ran GREEN. These checks also run in the
default offline Workbench suite. They do not launch a VM or write a socket, and
are not evidence of a guest exploit or a Stop bypass in other paths.

Model and MCP gateways have an optional host-owner registration hook: composition-created
gateways register pending installs, existing-handle attachments and in-flight
operation lifetimes. This includes service/test handles never projected as UI
cards. Existing standalone diagnostic gateways retain their standalone behavior.
The hooks do not change transport, parser, authentication, F03 clock/Stop, concrete
resume or controlled-output acceptance semantics. Issued tickets still settle
through the existing authority exactly once; terminating authorization does not
retract bytes or side effects already handed to the OS/upstream.

Every composition install suspension checks close/configuration generation again
before publishing a handle. A late authority install is terminalized and retained
for cleanup, never exposed as an execution-eligible attachment. Workbench ingress
also rejects late grant/proposal/approval publication. The settings controller
owns its detached storage task before yielding, cancels queued work on close,
and continues to suppress late publication. An already-entered synchronous
storage operation is not forcibly interruptible and may finish after close;
shutdown does not wait for that OS storage call.

`WorkbenchChecks --composition-close-only` exercises the real owner APIs with
synthetic storage and an offline URLProtocol producer. It covers hidden queued
output, a blocked authority/workbench attachment, pending implicit model/MCP
installs, all eight before/after authority/model/MCP/workbench transition barriers,
delayed model preparation, cancellation of a started request, exact-once outcome
settlement, repeated close, post-close reuse rejection and a queued credential
check. Transition scheduling seams and pending-work diagnostics are Debug-only;
they supply neither permission nor fabricated business output. The default
Workbench entrypoint retains the original assertions and settings groups and
also runs these close checks. This is not rendered GUI, actual Keychain, live
provider, native consumer integration or real VM shutdown evidence. In particular,
a diagnostic lifecycle becoming terminal is not proof that a VM has stopped.

The ownership-intake repair was witnessed RED in nine permanent checks: foreign
handles at the model, MCP and workbench entrypoints, plus omitted/invented
connection metadata at each entrypoint. The foreign checks execute and accept
ordinary output through the original owner's real offline model transport after
the receiver closes; they measure credential reads, resumes, arrivals and durable
completion independently. All nine then passed. Three same-authority pending
attachment checks and one injected cleanup-failure check were added as
**first-GREEN coverage**, not claimed as additional witnessed failures. Original
close checks, original workbench assertions and settings groups remain intact.

The earlier ownership-intake review did **not** cover the later bounded ownership,
attachment-return or ticket-settlement changes. The current candidate adds a
32-entry pending reservation limit and a 32-unique-run retained ownership limit.
It reserves before authority allocation, shares genuine repeated attachments,
and retires only terminal ledger entries without pending resources; it does not
evict F03 replay state or unfinished tickets. Failed intake releases its
reservation, allowing sequential reuse rather than imposing a lifetime quota.

Direct model/MCP installation rechecks the owner's generation before returning,
including the duplicate-handle path. A configuration change while intake is
suspended rejects that return even when its installed grant has no affected
connection. Close remains synchronous at the seal and terminalization boundary.

Workbench-issued tickets transfer the reservation to the actual F03 dispatch
record through a package-only outcome-bookkeeping API. Completing through either
the workbench or authority retires that same reservation once. Wrong-handle,
invalid-outcome and replay attempts do not release it. Gateway operations retain
their resource registrations until their existing completion/error paths settle.
A failed durable completion marks cleanup unconfirmed before releasing the
registration: `close()` and repeated `close()` both remain false, with no retry,
invented success record or restored execution permission.

`swift run WorkbenchChecks --composition-bounds-only` covers preallocation
saturation/recovery, duplicate/repeated attachment, direct exposure barriers,
issued-ticket capacity, failed settlement and exact-once owner release counts.
The default offline Workbench suite includes these cases after all original
assertions, settings and ownership-close checks.

After `swift build --product WorkbenchChecks`,
`python3 Tests/MCPIntegrationTests/composition_close.py` runs four real authenticated
loopback cases through the unchanged MCP fixture: queued-result close, running
call close, failed completed-outcome audit and failed unknown-outcome audit.
Each case measures four credential reads, resumes and HTTP arrivals (three
discovery operations and one tool call), plus completion count, retained work,
consumer acceptance and repeated close. Response barriers acknowledge actual
handler arrival; they are not sleep/FIFO assumptions. Only the completed-outcome
cleanup failure was a newly witnessed RED in this four-case slice; the remaining
cases first ran GREEN and are coverage, not invented historical failures.

### Closed-clock composition and concrete native close control

The composition passes one closed `RunClock` into its existing authority; it does
not restore arbitrary wall/monotonic constructor callbacks. Attachment scheduling
fixtures use a separate `CloseBarrier`, not the clock. Their package-only
`withPreAcquisitionBarrier` holds the authority actor before attachment validation
or installation, without any lifecycle/operation/receiver lock. It is compiled
only for Debug or explicit test-fixture builds, not the normal Release product.
All original barrier-entry, timeout, ownership and settlement assertions remain.

`WorkbenchChecks --composition-native-close-only` uses the composition-installed
model handle, a real URLSession producer with offline protocol interception, and
an actual owned AF_UNIX socket. The positive control drains a full native response.
The close control commits a real partial prefix, synchronously closes the
composition, then verifies no new write call or late complete-event acceptance;
previously committed peer bytes and counters remain truthful. It measures source
credential reads, resumes, protocol arrivals, durable completion/audit sequence,
and drained ownership/registration counts. Both controls first ran GREEN; neither
is presented as a newly witnessed pre-fix failure. The default Workbench suite
also runs them. This is local socket delivery, not VM/device binding, rendered GUI
or external-provider interoperability.

**Activation blockers remain:** the combined clock/composition increment needs a
new independent review before activation. Credential preparation and
detached storage retain check-to-entry scheduling gaps, so these checks do not
establish a universal physical credential-read-start-after-close guarantee. An
already-entered synchronous storage call may finish after close. Raw legacy
callback/DTO consumer surfaces remain outside controlled receiver acceptance.
No storage or lifecycle framework was added; no rendered GUI, actual Keychain,
VM shutdown or external-provider success is asserted by this increment.

`WorkbenchChecks` uses actual F03 controllers, temporary JSONL files and explicitly synthetic test-only grants. It checks empty startup, snapshots, deny/dismiss, exact approved bytes, no auto-consumption, late rejection, timeout, connection revocation, awaited close, startup audit creation/write failure, runtime write failure, guest classification, bounded durable activity and side-effect-free view construction. Write failures are real OS failures induced only inside the check process by a temporary file-size resource limit; the prior limit and signal handler are restored. These are executable model checks, not GUI-interaction certification.

The already-retired regression was observed RED before the model fix: A was proposed, the clock advanced 301 seconds with the grant still live, and proposing B triggered F03 cleanup of A; timeout left A displayed. The checks now assert A absent and B present immediately after timeout/dismiss/direct deny, before any late approval can mask stale state. They also verify unchanged audit events, repeated dismissal, truthful direct-deny failure, and preservation and successful consumption of a real approval after a stale deny.

Verified on Apple Silicon / macOS 26.6.2 / Swift 6.3.3: `swift run WorkbenchChecks` passed 53 assertions; `AuthorizationChecks` passed 17 groups; `ContractChecks` passed 7 groups; foundation API and packaging checks passed 4 and 7 tests respectively. The Release App was packaged, locally ad-hoc signed and verified, and its `--diagnostics-json` command succeeded. Native launch produced an on-screen window belonging to that packaged executable; an explicit quit request to that exact process was accepted and the process exited. This native lifecycle check used only the empty default application.

GUI button/keyboard/sheet interactions are **BLOCKED** by desktop access permissions. Window-scoped image capture also failed, so visual layout has not been certified. Manual QA still must exercise Review, Return, Escape, sheet dismissal, Stop, window close and Quit with trusted-host test ingress. The default app intentionally has no demo buttons or synthetic-run switch. This increment does not establish VM execution, broker execution, G1/U01, or full F10 acceptance.
