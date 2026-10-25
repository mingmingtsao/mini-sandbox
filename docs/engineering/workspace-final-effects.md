# Workspace final effects

The installed workspace path now uses the existing `RunLifecycle` for received state, quarantine creation and writes, adoption of the complete result, and exclusive export publication. Installing or inspecting a grant remains a provenance check; it does not create a reusable execution permit. The original transfer protocol, path defenses, quota domains and stale-review checks remain in place.

## Identity and product ownership

`WorkspaceRunBinding` fixes the actual installed `HostRunHandle`, its epoch, grant start time, private store/snapshot identity, and workflow owner/generation. The quota registry binds those identities once. A foreign store, snapshot, handle or task cannot replace them. Guest frames provide data only and cannot select this binding. Workflow cancellation changes its irreversible generation; run Stop and expiry use the existing lifecycle generation and trusted clock.

`WorkspaceRunSession.bind` is the package facade for product code. Its caller transfers exclusive ownership of an imported store and snapshot; the store itself is not declared Sendable. Binding checks the authority's installed grant and snapshot, then installs the task policy before creating a transfer. One session prepares one transfer for its actual VM runtime UUID. The caller must use the VM owner's controlled connection and final frame writer for outbound bytes.

Result adoption requires a `BusinessVMStopReport` produced by the actual VM session. Its runtime UUID, run UUID and epoch must match, and actual stopped state and settled callbacks must be true. The report has no public/package memberwise initializer. A complete transfer is frozen, materialized, adopted and reviewed only through the owned session. Session cancellation terminates the run and cancels the task workflow, so queued run-scoped control or workspace frames cannot survive it. Receiver disposal after the callback ends releases retained payload, without refunding committed or orphaned disk.

## Concrete boundaries and clock

`WorkspacePreparedEffect` is a closed enum, not a callback API. Its concrete variants receive parsed state, freeze a complete receiver, create one directory/file, write at most 4,096 bytes, replace one prepared record table, or perform one exclusive `renameatx_np`. The final lifecycle call cannot accept arbitrary closures, await, queue an effect, or return a permit.

The effect acquires its receiver/store owner first, prepares parsing, hashes, path checks, buffer allocations and replacement tables, and acquires workflow ownership before the shared lifecycle. The trusted clock is sampled inside the lifecycle after those application-lock waits. The fence validates actual installed handle/epoch, run status/start time, store/snapshot, workflow generation and task provenance, then invokes the concrete bounded effect directly. Neither the effect nor its final owner validation waits for another application lock inside the lifecycle. The whole copy and `fsync` are outside the global fence. Each partial write or EINTR retry re-enters it.

Receiver file capacity is reserved before allocating a fixed-size buffer. Final chunk acceptance copies at most 4,096 bytes into unique storage without expanding it. Sequence/completion state changes share that fence. Prepared previous dictionaries and payload owners stay alive beyond the final lifecycle/workflow region. Payload reservation settlement happens after lifecycle release; already accepted bytes remain charged if Stop wins next. Cleanup and cancellation do not run inside the lifecycle.

Quarantine adoption retains both record generations, prepares the replacement table outside the fence, and replaces the table only while the exact store/snapshot binding remains valid. Failed adoption never becomes the snapshot's working directory. Export keeps the immutable review digest, retained destination parent, exclusive stage name and new basename together through publication. Cancellation or expiry first prevents rename; rename first remains committed even if the run becomes terminal immediately afterward. Post-commit verification failure is `committedUnverified`, never a reason to delete published user files.

A separately approved export after Stop uses a new host action cancellation and an already captured immutable review. It still enforces destination identity, stale/foreign review and the same task disk ledger. It never clears the old workflow or restores run authority. This API does not itself constitute user approval.

## Native verification

`swift build --product WorkspaceTransferChecks` and the actual executable passed 137 distinct checks: the previous 116 plus 21 lifecycle cases. The new cases first ran green; they are not claimed as independently witnessed behavioral REDs. Existing real short-write/EFBIG settlement, committed/orphan accounting, exact limits and stale-review tests are retained.

| Boundary | Concrete observation |
| --- | --- |
| Receiver Stop, wall expiry, monotonic expiry, task cancel | No chunk accepted; zero remaining reservation; poisoned and incomplete |
| First write versus Stop/expiry/cancel | Zero actual bytes written, no adopted or surviving quarantine |
| Stop/expiry/cancel after first chunk | Exactly 4,096 of 8,192 bytes written; no adoption; exact cleanup/settlement |
| Complete materialization before rejected adoption | Exactly 8,192 bytes written; zero committed bytes; working tree unchanged |
| Terminal before rename | No destination; only the prior 8,192-byte adopted tree remains committed |
| Rename before terminal | Destination exists with exact bytes; 16,384 bytes remain committed |
| Real lifecycle or workflow mutex held across exact expiry | Waiting writer performs zero bytes after release; expiry remains terminal after wall rollback |
| New host export after Stop/expiry | Exact immutable bytes exported; old transfer remains rejected |

The fixture creates synthetic temporary files and uses a manual trusted clock. On a system where `TMPDIR` names `/var` through a symlink, resolve that test root to its real path before running; do not relax WorkspaceStore's no-follow path policy. The existing 312-byte final-output clock regression and native socket modes belong to `ExecutionBoundaryChecks` and must be run explicitly on the integrated candidate.

## Evidence limits

These native checks exercise local file effects and accounting. Hostile same-UID/root filesystem isolation and universal filesystem latency bounds are outside this mechanism. Payload counters exclude allocator/parser overhead and the other exclusions documented in the transfer specification. The existing 256-run quota registry remains bounded and fail-closed without retirement. The product path binds the actual VM connection owner, stopped/callback report and App approval flow.
