# Opt-in bounded request-shape measurements

This is a diagnostic extension of `pinned-cli-local-capture-v1`, not an Agent/provider compatibility adapter. Enable it explicitly when building an image:

```sh
python3 Tools/AgentRuntime/build.py "$RUNTIME_DOWNLOAD_ROOT" "$DIAGNOSTIC_BUNDLE" "$NEW_IMAGE" --agent-probe --structural-metrics
```

The builder adds a fixed `/runtime/structural-metrics-v1` marker and records `structuralMetricsV1: true` in the manifest. Without that option the marker is absent. The supervisor adds only the capture process's `--structural-metrics` argument; vendor argv, replacement environment, fixed stdin, 30-second vendor deadline, 35-second capture lifetime, 37-second capture outer deadline, cleanup, and VM resource bounds are unchanged. The capture remains a separate process; requests still receive only the static unsupported response, normally HTTP 503.

## Privacy and bounds

The default capture shape and original tests remain unchanged. Opt-in output contains only fixed keys, closed enums, booleans and nonnegative safe integers. It never exports prompts, system text, tool names, arguments, arbitrary key names, IDs, auth, environment values or raw request/vendor output. Known enum values are recognized only in their specific fields; other values become `unknown`, not new labels. Missing optional numeric fields are `absent`; wrong types or unsafe numeric values are `invalid`.

The existing 1 MiB request, 4 MiB aggregate ingress, 16-connection, read/frame and absolute ingress deadlines remain. Additional metrics traversal is bounded to 32,768 value nodes and root-zero depth 64. Schema depth and node counts use the existing ModelJSON convention: containers/scalars are value nodes, object keys are not. Decimal/exponent/negative-zero tokens and unsafe integers are counted separately without converting them to accepted integers. Strings and schemas are measured without constructing a serialized request body. Schema bytes mean compact UTF-8 JSON with unescaped slashes, not Swift JSONEncoder canonical bytes or an approved envelope. Lone surrogates, duplicate decoded keys and nonfinite constants fail with static errors.

Retention reserves space below the supervisor's unchanged 16 KiB pipe budget. If another detailed record would exceed the 15,000-byte retention threshold, it becomes a fixed `metrics_omitted` record retaining its status. Such a record is not a successful measurement. Expiry is rechecked after analysis and serialization. These bounds are not a preemptible JSON CPU deadline; the separate supervisor supplies the process lifetime boundary.

## Measured mismatch, not compatibility

A real pinned 2.1.309 Linux aarch64 musl CLI launch in the no-NIC/no-share VM produced six 45,508-byte requests. The initial metrics run observed `stream: true`, `max_tokens: 32000`, adaptive thinking, high effort, three system text blocks totaling 5,758 UTF-8 bytes with two cache-control fields, two messages, and twelve tools. Tool name maximum was 23 bytes, description maximum 3,502 bytes, compact schema maximum 1,946 bytes, schema depth maximum 7 and value-node maximum 63. Schema noninteger and unsafe-integer counts were zero. The final run distinguished an absent thinking budget from an invalid value. One unknown thinking field and one unknown tool field were counted; their names and values were not retained.

Concrete blockers against the existing source contract:

- `max_tokens: 32000` exceeds `maxOutputTokens`'s 8,192 maximum.
- Adaptive thinking cannot survive an encoder that always emits disabled thinking.
- System block/cache-control structure cannot be preserved by joining system messages into one string.
- `metadata`, `context_management` and `output_config` are present but absent from the approved DTO/encoder surface; high effort is not preserved.
- An unknown tool field requires explicit support or rejection, not silent removal.
- Separately, the unchanged launch source selects `deepseek-chat`; the fixed model enum accepts `deepseek-flash`. This is a source-derived mismatch, not an exported model-string measurement.

Observed counts, name grammar/uniqueness, descriptions and schema depth/nodes/numeric domain were within their respective limits. This does not validate message blocks, tool-result semantics or the entire request. In particular, 45,508 wire bytes do **not** prove that a reconstructed ActionBinding envelope fits 65,536 bytes or the actual grant's `messageBytes`. Canonical serialization overhead and the actual wrapped request remain unmeasured. Stream `true` must be deliberately mapped to the host's separately authorized streaming argument.

The next adapter needs an explicit model/token policy, field-complete immutable approval reconstruction, system/cache/thinking/effort semantics or fail-closed rejection, exact schema and wrapped-byte validation, and real SSE/tool-result continuation. It must not loosen limits, silently drop fields or synthesize provider success. No model turn, provider response, tool continuation, broker integration, App/GUI workflow or full compatibility PASS is established here. Actual version/help exits, vendor timeout/wait status, Linux group cleanup, settled VZ stop and exact source/artifact digests belong in each private run's evidence.
