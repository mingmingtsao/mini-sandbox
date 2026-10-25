# Final-effect clock and lock order

This document specifies the scoped final-invocation boundary. It does not establish
application integration, production activation or release acceptance.

## Before

- `RunLifecycle.observeAndReduce`: arbitrary wall/monotonic providers → lifecycle mutex → reducer.
- Model and MCP actual start: credential/input preparation → providers → lifecycle mutex → operation mutex → concrete `URLSessionDataTask.resume()`.
- Native acceptance: serialize/enqueue outside authority → providers → lifecycle mutex → receiver try-lock → one nonblocking `send`.
- Compatibility acceptance: providers → lifecycle mutex → blocking receiver mutex → consumer-state mutation.
- Stop/connection retirement: lifecycle mutex → detach operations → unlock → operation cancellation.

The independent historical socket witness committed 312 bytes after waiting for the lifecycle mutex across exact expiry. This is an expiry race, not proof of a post-Stop bypass. The original probe/source/binary/log remain historical evidence. A newly composed candidate reproduced 312 bytes before this repair.

## After

- A single closed `RunClock` source supplies installation and the existing F03 lifecycle. Production constructors default to `.system()`; arbitrary wall/monotonic callback initializers are removed, not retained as a fallback.
- Preparation, credential reads, serialization, compatibility validation and consumer-value construction precede the final lifecycle fence.
- Start: operation mutex → lifecycle mutex → concrete paired clock sample → existing reducer/scope/deadline/cancellation checks → concrete resume and registration → lifecycle unlock → operation unlock → detached operation cancellation.
- Accept: receiver ownership (native try-lock; compatibility blocking lock) → preparation → lifecycle mutex → concrete clock sample → existing reducer/scope/cancellation checks → one nonblocking send or prepared in-memory adoption → lifecycle unlock → detach cleanup under receiver ownership → receiver unlock → descriptor close and retained-value releases.
- A failed native try-lock still observes/reduces/validates the lifecycle but cannot write, dequeue, or issue a permit. Every partial/EAGAIN/EINTR retry reacquires ownership and resamples.
- Stop and connection retirement never acquire operation/receiver mutexes while holding lifecycle. Their detached cancellation runs after lifecycle unlock. Error-path drains from start/accept wait until *both* fences have been released.

Only F03 owns high-water time, the fixed installation-relative monotonic deadline, irreversible terminal generation, connection revisions and registrations. There is no second lifecycle, preissued permission, queued task hop or callback clock under the final fence.

## Constructor API and compatibility

The constructor interfaces are:

- `RunAuthorizationController(auditSink:clock:)`, default `RunClock.system()`.
- `HostModelGateway(connections:auditSink:clock:authority:)` and `HostMCPGateway(...)`, same default; supplied authority remains the shared reference.
- `RunComposition(audit:modelConnections:mcpConnections:clock:)` passes that concrete source to its authority.
- `WorkbenchModel(newAuditFileAt:clock:authority:)`, same default.
- Standalone diagnostic lifecycle uses `.system()`; installed diagnostic sessions retain the supplied lifecycle.
- Test wrappers expose `.source` rather than passing `now`/`monotonic` closures. `RunClock.manual(wall:elapsed:)` is package-only. Omitting elapsed explicitly selects real ContinuousClock elapsed time; supplying `.zero` selects deterministic manual elapsed time. `SharedHostClock` explicitly selects manual elapsed for all shared pulse/rollback tests. Existing wall-only TestClock, model/MCP and workbench wrappers explicitly retain real elapsed time.
- `StartGateClock` and proposal/shared expiry pulses are data-only scripts. Pulse counters still assert the pulse fired. No test clock blocks or calls arbitrary code.
- Existing `stop-during-final-observation` and native observation-race names are retained: their formerly blocking clock fixture is now an explicit pre-acquisition test barrier. They prove Stop/cancel before concrete acquisition, not a pause inside the final clock read. Additional R3 tests hold real lifecycle, compatibility receiver and model/MCP operation mutexes across expiry.

Apply these constructor changes without replacing the composition's ownership,
closing or settlement behavior. A shared clock does not replace immutable
same-authority attachment provenance checks or prove application-close coverage.

## Build configurations

Normal Debug all-target and normal Release `MiniSandbox` product builds are separate checks. Optimized executable regression checks require `-Xswiftc -enable-testing -Xswiftc -DSANDBOX_TEST_FIXTURES`: the existing internal malformed-MCP fixture constructor was Debug-only and otherwise prevented the preserved receiver-defense cases from compiling in Release. The explicit fixture define does not change the clock or lock path and is absent from the normal Release application build. It is not a production capability or approval to execute real credentials.

## Boundary

This is final invocation ordering after all application-controlled lock waits. It does not claim clock-read/syscall physical atomicity, hard realtime latency, remote receipt timing or retraction of bytes already accepted by the OS. Compatibility/raw gateway DTO and callback APIs remain diagnostic surfaces, not a newly approved default production activation. No new network privilege, credential cache, guest secret or provider bypass is introduced.
