# Business VM ownership

`BusinessVMSession` owns one fresh VZ machine for an already installed host run.
Construction compares the authority's immutable installation with the exact
handle and grant. The pinned business resource manifest is data-only and is
checked with strict bounded JSON, owned regular-file reads, and SHA-256 before
the VM is built. The resource directory is explicitly selected; no developer
cache path or inherited PATH is searched. Input paths must remain non-mutating
until VZ stops, because the framework reopens them.

The VM has two vCPUs, one GiB RAM, a new 64 MiB session disk, a fixed read-only
vendor disk, zero network devices and zero host directory shares. Port 4060 is
task control, 4062 workspace transfer, 4064 model HTTP, 4065 tool permission and
4066 reserved MCP. Enabling a listener does not grant a service capability.
An unimplemented service is closed by its host consumer.

Only the actual registered listener and `VZVirtioSocketDevice` can create a
`BusinessVMConnection`. Its run, lifecycle, epoch, runtime, service and channel
identity come from the host. At most eight channels and two model/MCP channels
per service are retained. The native response consumer takes one owned
duplicate, then retires the original on the VM queue after terminal cleanup.
Raw-fd diagnostic APIs do not gain VZ authority.

VM start uses the existing lifecycle's closed concrete effect set. Control and
workspace frames use a concrete immutable writer. Writer and connection
ownership precede the lifecycle fence; the fence samples trusted time after
those waits, validates the actual run/generation/scope, then invokes one bounded
nonblocking send. Every partial/EAGAIN/EINTR retry enters again. Permission
frames additionally require a connection scope and action identity from their
trusted policy/approval producer. The writer is not itself permission policy.

Cancellation terminalizes the run synchronously, then removes listeners and
retires channels on the VM queue. Start completion rechecks closing and
generation before announcing availability. `waitUntilStopped` reports actual
VZ stopped state, settled start/stop callbacks, and session-disk removal
separately. A teardown timeout reports failure and retains framework resources
while callbacks remain pending; it never reports a fabricated stopped state.
Natural result completion stops the VM before the coordinator adopts its
immutable received tree. It does not revive an expired or stopped run.

These APIs are integration infrastructure. Native request/permission parsing,
the actual CLI profile, application orchestration, original-project preservation
and end-to-end acceptance must be verified together on the selected candidate.
Offline path and manifest checks are not evidence of a real VM or Agent task.
