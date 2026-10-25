# Controlled execution/output increment

This document describes host-side transport start and controlled consumer acceptance interfaces.

## Actual effect boundaries

`RunLifecycle` is the existing run authority. Its mutex now also orders:

- terminal state and generation changes;
- connection invalidation and catalog-revision invalidation;
- a closed enum of concrete `ModelPreparedOperation` / `MCPPreparedOperation` starts, which directly call `URLSessionDataTask.resume()` before returning;
- one bounded `ControlledRunOutput.acceptNext()` mutation of consumer-owned state.

Gateway request reconstruction, version validation, credential reads, suspended-task construction and audit appends remain outside the mutex. The gateway actor validates the immutable approved envelope against its connection registry; the lifecycle fence then checks the captured generation/connection revision, invalidation state, action start deadline, not-before time, task cancellation and the prepared operation's one-shot state at the concrete start. No start callback, queued permit, Task or await exists in that critical section.

Trusted clock providers remain outside the mutex. Their observations are reduced under the same fence, retaining the existing wall high-water and fixed monotonic-deadline semantics. These tests establish ordering of the synchronous `resume()` call against observed terminal/invalidation state, **not atomic physical provider entry or network arrival**. OS callbacks may arrive later.

Started operations are registered in the lifecycle. Terminal observation/Stop and connection invalidation detach matching registrations while holding the mutex, then cancel outside it. Gateway deferred cleanup still releases capacity; transport terminal handling remains one-shot. Already-started failure/cancellation remains unknown, without retry. A completed audit records upstream completion, not downstream acceptance.

## Controlled output API

The new overloads take a receiver created by `makeOutput(handle:approval:)` and return `Void`. A receiver is bound to the exact lifecycle, generation, connection revision and action ID. Producers enqueue typed chunks/completions; enqueueing does not authorize acceptance. The caller explicitly drives `acceptNext()`, which checks the same lifecycle at the actual mutation of owned text, metadata, completion and MCP tool-result state. No arbitrary callback executes under the fence and no completion DTO is returned by this overload.

The receiver has a 256-event queue and an 8 MiB cumulative value-size budget. Producer failure or explicit cancellation closes its queue. Backpressure is failure, not silent drop or retry. Consumer state is deliberately not a transferable tool-execution capability. MCP tool-result conversion is performed inside acceptance; it is not a subsequent model request.

Consumer acceptance is transactional: validate all fallible event data before changing accepted text, completion, metadata, finals, tool results, event counts or dequeuing. A malformed MCP source ID throws `denied` and leaves the same head queued and all accepted state unchanged, including on repeated attempts. Explicit cancellation may discard that queue without recording acceptance. Proposal ingress and receiver defense both use `ModelBlock.validID`; a nil source ID is valid and produces no tool result. The debug-only internal fixture factory deliberately bypasses ingress to exercise receiver defense independently; its completions are synthetic, not authenticated transport evidence.

## Compatibility surfaces and scope

- Existing raw-returning `execute` overloads and Model `emit` remain for compatibility. Their consumers are **not** covered by the new acceptance contract.
- `MCPModelHandoff.propose(completion:...)` and `toolResult(...)` are raw DTO APIs. Their values do not authorize destination acceptance; callers using controlled output must retain consumer ownership and enter its acceptance boundary.
- The MCP controlled receiver is limited to approved tools/call; discovery/control operations use the existing gateway path. Successful discovery and failed refresh invalidate old connection-revision outputs, but discovery/catalog registry mutations themselves are not yet inside the output fence.
- Direct standalone transport APIs are not run-bound gateways.
- Credential-provider entry itself is not atomic with Stop. An already-entered preparation may return afterward, but its suspended task cannot pass a terminal start fence. No credential preloading or cross-request cache was added.
- Physical network cancellation cannot reverse an already committed remote side effect.

## Offline verification entrypoints

- `swift run ExecutionBoundaryChecks`: concrete resume/consumer barriers, blocked preparation, expiry rollback/action deadline, connection isolation, actual URLProtocol model streams/nonstream and metadata/final, proactive cancellation with reentrant OS cleanup.
- `python3 Tests/ExecutionBoundaryChecks/loopback.py`: real authenticated host fixture, controlled MCP completion/tool-result acceptance and queued-output Stop; synthetic bearer only over stdin, independent HTTP ingress counts.
- `ExecutionBoundaryChecks --receiver-transaction`: synthetic malformed-event rollback, queue retention, idempotent cancellation, valid/nil commits; also included in the default boundary checks.
- `python3 Tests/ExecutionBoundaryChecks/loopback.py --transaction`: malformed proposal rejection with zero extra credential reads/resumes/HTTP, then real valid/nil accepted results and capacity reuse.
- Existing AuthorizationChecks, HostIntegrationChecks, StructuredModelChecks, WorkbenchChecks, SharedAuthorityChecks and both MCP loopback scopes remain required. The MCP scopes retain response-loss/no-retry and four credential-reflection negatives plus two controls.

Do not run the default credential-store transport suite as an offline substitute.
