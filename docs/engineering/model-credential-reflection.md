# Active model-credential reflection boundary

The host model transport rejects an upstream response that reflects the **exact
credential used by that request** into returned text, supported structured tool
values/keys/IDs/names, or exposed metadata strings/usage counters. Validation happens in
the request-private transport delegate after protocol decoding and before any
completion or stream chunk leaves the transport. An internal decoded object is
not yet business output. Rejection is `invalidResponse`, not redaction or empty
success. The existing gateway records a started request as `unknown`, never
retries it, and cannot append a successful completion for the rejected response.

This is literal active-value matching, including JSON unescaping at the protocol
boundary. It is **not** generalized encoded-secret DLP, arbitrary transformations,
credential discovery, protection against unrelated secrets, or a full security
verdict. Error bodies remain discarded; diagnostic errors remain static categories
or HTTP status codes. No response content is inserted into an error or audit.

## Incremental streaming

- A per-operation linear prefix matcher tracks the longest suffix that could
  still become the active credential. Text before that suffix is released
  immediately, including when safe text and the suffix share one SSE event.
- Matching continues across text deltas and adjacent text blocks. The complete
  credential cannot be reconstructed from text fragments already released.
- Text events may be split into a safe prefix and a later text delta. Block and
  metadata ordering and all valid content are preserved; no tool block is dropped.
- A tool block's start and raw argument fragments are held until its block-stop
  event has parsed and validated the complete decoded JSON object **and** the
  concatenation of the exact raw fragments. Decoded checks cover unescaped
  strings/keys and every supported primitive; literal raw checks also cover
  escape spellings and values spanning JSON syntax or spaces across fragments.
  The codec's existing 65,536-byte argument limit bounds this concatenation.
  Fragments are released unchanged, never reconstructed from encoded JSON.
- A pending text prefix can hold following structural events to preserve order.
  The existing 4 MiB response cap bounds the total wire input; the guard also
  bounds its queued text/argument bytes and event count. Ordinary text is not
  buffered wholesale until EOF.
- A harmless prefix remaining at a genuine final event is preserved, not removed.
  Its queued events are marked for the existing gateway completion-audit barrier;
  audit failure, Stop, and cancellation suppress their release. Truncation or
  malformed data never triggers this successful flush.
- OpenAI streaming now supplies an assembled completion while retaining its
  event-less final marker. Its response-size-bounded transcript preserves the
  trailing audit-held text in the returned result; ordinary chunks still arrive
  before EOF. Anthropic continues using its existing assembled completion.

The guard is created during the existing per-request preparation using the same
credential read as the authentication header. It is not cached, preloaded, stored
in a connection, or added to any business DTO. Every terminal path clears its
credential reference, matcher arrays, transcript and pending events. This is
reference/state cleanup, **not a claim of secure heap zeroization**; URLSession
continues owning its normal request header for the request lifetime. The guard's
private lock never encloses lifecycle callbacks, credential reads, or audits.

## Offline regression scope

`StructuredModelChecks` retains its prior named checks and adds transport-level
reflection, gateway unknown/no-retry/capacity-reuse, sanitized error/provisional
output, complete tool ordering, early ordinary text, and delayed-prefix audit
checks. The original reflection canaries are generated in memory. The primitive
regressions additionally retain fixed, public synthetic examples (including
`424242`, `true`, `false`, and `null`) in test source. Neither fixture response
bodies nor credential values are printed by the checks; runtime evidence records
static labels, counts and booleans only. No real credential is used.

The first permanent transport matrix was executed against the unmodified
production transport: all 17 reflection shapes reached successful output instead
of rejection. Follow-up REDs independently exposed premature pending-prefix
release at the audit boundary, withholding ordinary text sharing an event with a
prefix, and omission of an audit-held OpenAI suffix from the returned completion.
The expanded channel/control cases are additional verification, not retroactive
claims that each independently witnessed RED.

The legacy model fixture now uses a runtime-generated `sk-`-prefixed synthetic
credential instead of an English-word credential whose first letter coincided
with the last letter of the early-text fixture. Its named tests, exact early
text assertion, active-credential provider-failure bodies, and header assertions
remain intact. There is no production short-key exemption.

Run `StructuredModelChecks` without live flags for these offline checks. The
`ModelTransportChecks` default includes Keychain CRUD: when Keychain is excluded,
select the 32 exact offline names, exclude `isolated Keychain CRUD`, and compare
the deduplicated result-name set because selectors use substring matching.
No live-provider, Keychain, VM, GUI, Agent or release acceptance is implied.

## Primitive and raw-fragment boundary

`ModelJSON` exposes objects, arrays, strings, safe signed integers, booleans and
null. Matching recursively covers all of them: integer decimal representations,
both boolean literals and `null` are checked without changing their types or
values. There is no short/numeric-credential exemption. The actual raw grammar
already rejects decimals, exponents, leading-zero integers and negative zero;
those are malformed-input controls, not claimed reflection reproductions.

Usage counters are nonnegative integers and are checked alongside their keys at
message start, cumulative message delta and completion. Other exposed metadata
strings (including the typed service tier) retain their checks. A final usage
value in the real SSE decoder is inherited from start/delta, not introduced by
`message_stop`; rejecting the earlier value prevents its final reconstruction
from reaching a caller. Optional metadata nulls become absence, not a returned
JSON null literal. JSON null inside tool input remains an actual payload value.

Local protocol structure is separate: block indices are computed from the
decoder's block count (the wire index must equal it), and final/terminal flags
are local control state. They are not arbitrary upstream payload values. Response
tool-result blocks, including their `isError` flag, are rejected by both codecs.
HTTP status diagnostics remain protocol status codes, not scanned response-body
content. This boundary does not promise matching across arbitrary serialization
of an entire DTO or arbitrary concatenation of unrelated fields.

Permanent CR-01 checks first ran against the unchanged held production guard:
string rejection worked while primitive/usage payloads reached transport output,
gateway nonstream success and SSE callbacks. A deliberately held completion audit
proved numeric, boolean, null and raw-fragment payloads had already escaped before
its subsequent injected failure. The repair checks these representations at the
same pre-release transport boundary, not merely at final DTO return or audit.
The injected audit-failure checks distinguish failed durability from a recorded
unknown outcome; they do not claim a physical disk-failure test. Ordinary typed
payloads and exact raw fragments/order, early text before EOF, cancellation,
truncation and pending-prefix audit gating remain covered. These local checks do
not replace the independent human follow-up or authorize component activation.


## Real loopback and final native consumer

The additional `Tests/ModelReflectionTests/loopback.py` driver launches an owned
`127.0.0.1` HTTP service and runs `ExecutionBoundaryChecks
--model-reflection-loopback`. A **test-only** URLProtocol forwards the fixed
production request to that service; production endpoint selection is unchanged.
The service consumes the single random canary injected by the real transport and
returns success/error JSON, escaped strings, adjacent text blocks, tool input,
and delayed SSE fragments. No credential is printed, persisted or passed through
argv. This is actual loopback transport plus the final native socket consumer; it
is not an external provider, vendor CLI, VM, UI or diagnostic-App acceptance claim.

The host pumps `ControlledRunOutput.acceptNext()` while the upstream is producing,
and independently reads and reconstructs the actual peer HTTP/SSE payload. Merely
clearing an unconsumed queue after detecting a leak cannot pass this test. Thirteen
cases independently observed thirteen upstream HTTP arrivals and thirteen single
credential reads/resumes. Five reflecting nonstream cases and the error-body case
committed zero peer bytes. Three reflecting SSE cases allowed only safe prefix
metadata/text, no complete canary or escaped argument, and no terminal success.
Four positive controls preserved ordinary text, tool input and a harmless trailing
credential prefix through successful completion. Started rejection outcomes were
audited as `unknown`. Actual byte counts are printed per case.

Reproduce without any live flag or Keychain access:

```sh
swift build --product StructuredModelChecks
swift run --skip-build StructuredModelChecks
swift build --product ExecutionBoundaryChecks
python3 Tests/ModelReflectionTests/loopback.py
swift run --skip-build ExecutionBoundaryChecks --native-response
swift run --skip-build ExecutionBoundaryChecks --native-repairs
swift run --skip-build ExecutionBoundaryChecks --final-effect-clock
```

The migrated reflection regression set was run before the production change on
the current main baseline: 52 groups passed and 11 failed. With the repair, all 63
groups passed. These are scoped local results, not independent human approval.
The exact production diff and these reproduction commands form the review unit;
real-credential activation remains dependent on the required human review.
