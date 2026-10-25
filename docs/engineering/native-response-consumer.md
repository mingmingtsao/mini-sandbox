# Native response consumer: local socket increment

Status: executable local consumer with final-invocation fencing; production
connection ownership and application integration remain unverified.
This is not evidence of an external provider, vendor CLI, VM/device ingress, GUI,
or the complete application task chain.

## Binding and authority

The trusted host passes one exclusively owned, already connected AF_UNIX stream
socket to `HostModelGateway.makeNativeOutput(handle:approval:takingAcceptedSocket:)`.
Ownership transfers on invocation, including validation/setup failure. The caller
must not close, reuse, mutate flags on, or retain another owning alias of that fd.
The factory accepts no guest run ID, route, connection ID, protocol or stream mode.
It derives the lifecycle reference, generation, connection revision, action ID and
streaming mode from the existing host handle and approved request. Only Anthropic
requests are supported; other protocols fail closed. This is an internal/package
host interface, not a guest API or a reusable delivery token.

Use the existing `execute(handle:approval:output:)` producer. It still prepares and
starts the real URLSession operation through the existing F03 lifecycle, audits
completion before terminal events, and cancels output on producer failure. No
legacy `emit` or raw completion handoff is introduced by this increment. Existing
legacy interfaces remain unchanged and are not declared migrated by these tests.

`ControlledRunOutput.acceptNext()` re-enters `RunLifecycle.acceptOutput` on every
attempt. The lock order is **receiver ownership, then lifecycle**. Native output
uses a nonblocking receiver-lock attempt; compatibility output obtains its
receiver lock before the final lifecycle fence. Fallible validation and prepared
consumer values precede that fence. The closed `RunClock` is sampled only after
these application-controlled waits, followed by the existing high-water/deadline
reducer, identity, terminal/generation, connection and cancellation checks.

The final operation is one concrete nonblocking `send`, capped at 16 KiB, or one
prepared in-memory adoption. There is no arbitrary callback, Task hop, await,
reusable permit or further application-lock acquisition between the final sample
and effect invocation. Serialization remains outside the lifecycle mutex; the
channel and descriptor remain private to the receiver. Terminal references are
detached under ownership and cancellation, descriptor close and retained-value
cleanup occur after the required fences have been released. The concrete start
path uses the corresponding operation-then-lifecycle order, not the reverse.

Every partial/EAGAIN/EINTR retry reacquires ownership and takes a fresh sample.
A failed native receiver-lock attempt can observe/reduce the lifecycle but cannot
send, dequeue or issue a permit. Stop/revoke that wins the lifecycle fence prevents
subsequent effects. Bytes accepted by the OS before terminalization are not
retractable and do not prove peer processing. This is final-invocation ordering,
not physical clock/syscall atomicity, hard realtime latency or credential-provider
entry atomicity. See [the final-effect clock contract](final-effect-clock.md) for
the full lock order and fixture/production clock distinction.

## Framing and bounded storage

The serializer uses `ModelCompletion`, `ModelMetadata`, `ModelBlock` and
`ModelStreamEvent`, not reflected descriptions. JSON has sorted keys and unescaped
slashes. Nonstream responses have an exact UTF-8 Content-Length. Streams use
`event: <type>\ndata: <JSON>\n\n`, native indexed text/tool events, cumulative
usage/stop metadata, and a genuine `message_stop`. HTTP responses specify
`Connection: close`; SSE is close-delimited, not falsely advertised as chunked.
The owned socket closes only after the final frame is fully sent, or on explicit
cancellation/disconnect. Tool-use bytes are data, never host tool execution.

Limits per channel:

- 256 queued frames;
- 2 MiB of retained frame bytes, **including the sent prefix of a partial frame**;
- 1 MiB per encoded frame;
- 8 MiB cumulative encoded response bytes;
- existing structured bounds: 128 blocks, 64 KiB active text/tool JSON, depth 32,
  and 8,192 JSON nodes for encoding.

Encoding counts the exact JSON grammar before allocating escaped output, using
the same bounded walker for sizing and emission. It accounts for control escapes,
quotes, backslashes, unescaped slashes, UTF-8, keys, integers and punctuation.
The actual HTTP header (including Content-Length digits) or SSE framing must also
fit the remaining frame, queue and cumulative response budgets. No sixfold
semantic estimate substitutes for those byte limits. An actually over-limit
response is rejected, never truncated. These are byte/storage limits, not an
exact process-RSS guarantee. Bounded reconstruction and a temporary candidate
frame are additional allocations. Original upstream/request/grant limits are
unchanged; the consumer does not expand upstream authorization.

Enqueue copies protocol state and commits it only after validation and both queue
limits succeed. Capacity returns only when a whole retained frame is released.
Receiver-lock contention, EAGAIN/EWOULDBLOCK or EINTR returns false without claiming success; retrying must
re-enter the lifecycle fence. False is **not EOF**: inspect `nativeProgress`.
`committedBytes` counts only positive syscall returns; `pendingBytes` counts unsent
bytes; `bufferedBytes` counts whole retained frames. `acceptedEvents` and
`acceptedFinals` advance only when their complete frame has been sent. The old
`summary` continues to describe only the compatibility in-memory receiver.

The future connection owner must schedule bounded retries/readiness and call
`cancel()` for abandoned output. Cancellation, terminal socket failure and finished
delivery discard pending frames and serializer reconstruction (blocks, active
text/tool fragments and metadata), without erasing historical committed bytes,
partial-write/EAGAIN counts or completed-frame/final counts. This is a retained
semantic-state claim, not a measured allocator/RSS claim. A disconnected or canceled `closed` channel is not a
completed response unless `acceptedFinals` says so. The descriptor is never
exported as a readiness/delivery capability.

## Executable checks

`ExecutionBoundaryChecks --native-response` uses owned local socketpairs and
checks bytes actually read by the peer, including:

- exact JSON text/tool framing and exact SSE text/tool/Unicode framing;
- Stop, exact expiry, revocation, connection-revision change and cancellation
  before acceptance (zero bytes);
- Stop/task-cancel at a pre-acquisition barrier, plus explicit lock-wait expiry checks;
- actual partial send and EAGAIN with a small socket send buffer, resumption with
  no duplicate/dropped bytes, Stop and disconnect after a committed prefix;
- no terminal tail after previously delivered text;
- event/frame/pending/cumulative limits, transactional rejection and reuse;
- ownership cleanup of an exclusively owned rejected nonsocket descriptor;
- the existing gateway producer through a real URLSession/URLProtocol fixture,
  wrong-action binding rejection, and native text received while upstream EOF
  and completion audit are still outstanding.

The initial in-memory-only receiver failed the exact socket-byte check. Separate
behavioral REDs showed missing SSE, the unbound gateway consumer, and capacity
incorrectly reclaimed from partially sent but still retained frames. Expanded
negative checks that first ran green are not described as witnessed REDs.
The original Boundary23, receiver transactional tests, Structured37 and Shared14
are retained; the current native-request combination runs Structured51. Real local
MCP controlled/transactional slices are separate checks.
No default credential-store suite is needed for this increment.

`ExecutionBoundaryChecks --native-repairs` adds permanent regressions for a
decoder-eligible three-block reply rejected by the old estimate, reconstruction
release and nonblocking native receiver contention. All three were observed
failing before the repair. Additional positive/negative controls exercise actual
decoder/socket equality at 1 MiB minus one, exactly 1 MiB and one byte over,
escaped keys/values and safe integers, exact HTTP/SSE overhead, repeated
non-consuming rejection, cleanup after a real partial write, and a two-tool
stream with three cumulative metadata deltas. The expanded boundary and
multi-tool controls first ran green; they are not claimed as separate REDs.

## Explicit remaining gates

- Fresh regression/review for subsequent changes and combined application integration.
- Trusted VM/device descriptor acceptance and real ingress identity binding.
- Production connection ownership, readiness scheduling and aggregate channel caps.
- MainActor UI adoption and App main-chain activation/composition acceptance.
- Independent validation of active-credential reflection through the final
  native/CLI/UI exits; request compatibility and local sockets do not prove it.
- Actual provider/CLI tool loops, real VM routing and end-to-end application proof.

Local sockets prove concrete OS byte commitment and fence behavior, not any of
those remaining integrations. Historical approval problems are recorded privately,
not retrospectively cured by these new, independently scoped executions.
