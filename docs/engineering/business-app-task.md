# App task integration

The Tasks tab uses the app-owned RunComposition and its single F03 authority.
The user chooses a project directory, verified business image and pinned CLI
disk, enters a task and selects the supported Claude profile. Codex/DSH and MCP
are displayed as unavailable. The model connection remains host-only. The
immutable product egress gate is still false, so this build cannot start a
credential-bearing task or claim external provider success.

The coordinator imports the selected tree on a dedicated actor and transfers
exclusive store ownership into WorkspaceRunSession. One immutable grant binds
that snapshot, actual image/profile hashes, selected model connection and local
workspace permissions. The VM has no NIC or shared host directory. Normal CLI
model and tool permission requests appear inline as exact one-action approval
content; Stop stays outside all scroll views and approval content.

The actual VZ model channel, run and runtime are included in each model approval.
The normal CLI stdio tool request binds exact arguments and its own VZ channel.
Only controlled native writers may return bytes to the guest. No host code runs
project commands, edits source on the Agent's behalf or manufactures tool results.
Guest stdout/stderr enters the concrete display consumer before UI projection.

The result requires both the guest finished record and a complete validated file
transfer with matching hashes, followed by the real VM stop report with settled
callbacks and deleted private disk. Only then may the same workspace session
adopt/review. The run is stopped before the result is offered for a separate host
export action into a new directory. Close waits for import, concrete VM cleanup,
attachment settlement and export cleanup. Cleanup failure keeps close false.

Validation: MiniSandbox builds; WorkbenchChecks and SharedAuthorityChecks pass.
New composition cases hold close until business cleanup ends, retain a failed
cleanup verdict across repeated close and reject a foreign equal-ID run owner.
These are in-process checks. Actual GUI interaction, VM/CLI and external-model
evidence must be recorded separately. The TabView now has explicit selection and
tags so an environment refresh does not reset the selected tab.

## Explicit local provider UI test build

An App built with `-DSANDBOX_TEST_FIXTURES` alone contains the optional launch
arguments `--local-business-fixture-port <port>` and
`--local-business-fixture-root <new-absolute-directory>`. Both are required; the
directory must not already exist. No host, key or credential file argument is
accepted. This composition uses only the fixed 127.0.0.1/public-canary transport
factory, never constructs a Keychain store, disables credential settings and
stores task data under the newly created test directory. Its UI displays
`LOCAL FIXTURE` prominently. Project/runtime selection, task consent, each model
and tool approval, actual VM cleanup, result review and export remain the same
MainActor/product path. There is no automatic task start or tool approval.

Normal builds do not contain this constructor or argument handling. The
production activation gate remains false in both builds. A successful fixture
run is evidence of real UI/VM/CLI execution with a local scripted provider only;
it cannot satisfy external-provider or release acceptance.
