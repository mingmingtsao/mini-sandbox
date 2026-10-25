# Fixed host model transport

## Scope

`SandboxHost` provides a host-only DeepSeek transport, with bounded structured Anthropic data described in `structured-model-tools.md`. Its v2 stricter-contract reconciliation passes all 29 retained non-Keychain model groups plus 3 additive rejection groups. It is package-visible, has no guest listener, and does **not** grant permission to call a service. The host gateway binds an authenticated run, a live authorization decision, and its dispatch boundary before using it.

The allowlisted model is `deepseek-flash`. Requests select only the fixed OpenAI-compatible text route or Anthropic-compatible structured route; there are no caller-supplied URLs or HTTP headers. The two routes are fixed to `https://api.deepseek.com/chat/completions` and `https://api.deepseek.com/anthropic/v1/messages`. Host credentials are added in the corresponding authentication header. Anthropic system instructions are carried in the `system` field, not discarded. Thinking remains explicitly disabled. The structured candidate transports text/tool-use/tool-result data, but never executes tools; image inputs, Agent adapters and MCP execution remain unsupported.

The default session is ephemeral, does not use cookies or a response cache, refuses redirects, and uses finite request/resource timeouts (60/120 seconds). Error messages report bounded categories/status codes, not upstream response bodies or credentials. Requests are not retried automatically. Injected `URLSessionConfiguration` is a trusted package-level test seam, never a protocol field exposed to guests.

## Bounds and streaming

- At most 128 messages; each message is nonempty and at most 64 KiB UTF-8. Output limit is 1–8192 tokens. Decoding calls the same validating constructors.
- At most 1 MiB encoded request, 4 MiB response and 256 KiB per SSE line.
- Four active requests per transport instance; excess requests fail immediately with `busy`. Cancellation and every exit path release the slot.
- Text chunks are delivered before EOF. SSE supports UTF-8 fragments, LF/CRLF/CR, comments and metadata fields, OpenAI `[DONE]`, and Anthropic lifecycle/`message_stop` events. EOF without a framed terminal event is an error. Non-text metadata is not represented as text output.
- The URLSession task is cancelled when the caller cancels or processing exits, including rejection and size-limit errors.

The prepared-operation refactor creates a suspended task; `start()` resumes it
synchronously once. Cancel-before-start and deinit-before-start never dispatch.
Repeated cancellation/deinitialization releases a reservation exactly once.
Direct completion checks task cancellation again after stream iteration (which
may otherwise end silently on cancellation) and requires a genuine final marker
before returning. Successfully decoded empty text remains valid; an Anthropic empty stream now
requires message start, message delta and message stop, with indexed block
lifecycles when blocks are present, not a bare terminal marker. A no-block empty
lifecycle emits three empty-text metadata chunks and exactly one final.
Empty iteration alone is not success.

OpenAI-compatible completion and SSE responses reject explicit `finish_reason` values `insufficient_system_resource` and `aborted` as `providerFailure` (`upstream generation failed`), even with HTTP 200 and partial text. No body, credential, or raw provider error is included. A failed SSE event emits neither its own text nor a success-final marker; previously delivered partial chunks cannot be retracted, and the consumer must handle the terminal error. A later `[DONE]` does not override the failure.

Other finish reasons retain the text-only behavior: `stop`, `length`, `content_filter`, and `tool_calls` preserve any supplied string text, rather than becoming provider failures. This does not guarantee an untruncated/unfiltered answer or execute tools. Missing/null finish reasons remain compatible; unknown reasons are not interpreted. SSE still requires a framed `[DONE]` for successful termination, not merely a finish reason.

Every Anthropic `type: text` completion block requires string `text` (including an allowed empty string); missing, null, or non-string text rejects the entire completion as `invalidResponse`. The structured candidate preserves supported tool-use blocks and rejects unsupported non-text blocks instead of ignoring them. JSON decoding failures in either completion protocol also return sanitized `invalidResponse`, not `network`.

## Credential storage

`KeychainModelCredentialProvider` uses generic-password items scoped by service/account (default `dev.mini-sandbox.model` / `deepseek`), with update and delete operations. It requests noninteractive access and does not fall back to disk or guest environment variables. Storage errors preserve only a numeric OSStatus. Test accounts use random names and disposable values and attempt cleanup. The isolated test checks create/read, a second `setCredential` and update readback, then delete/missing; authorization failure still marks the entire check BLOCKED, not PASS.

**The recorded CLI-context Keychain CRUD check was BLOCKED:** `SecItemAdd` returned `-60008` (authorization unavailable). A separate disposable-item probe reproduced that result. Read-only Keychain reachability from the foundation is not evidence that credential storage works. A signed native probe was also built, but LaunchServices could not launch it from the private test location (permission denied), so that run obtained no application-context CRUD result. Its native application-context result is recorded as BLOCKED.

## Reproduction and evidence

The metadata-merge revision passed **29/29 structured groups**, **38/38 host**,
**17/17 authorization**, **7/7 contracts**, **32/32 distinct non-Keychain model
groups**, and all-products Debug compilation. This revision also passed
**4/4 API boundary**, **7/7 packaging**, and the explicit Release `MiniSandbox`
application build and strict signature verification.
Those results and independent approval apply to the earlier metadata-merge
revision. The response-usage correction now passes **37/37 structured groups**
(29 retained plus 8 usage groups), **38/38 host**, **32/32 distinct non-Keychain
model**, **17/17 authorization**, **7/7 contracts**, **2/2 permanent CLI tests**,
and all-products Debug compilation. Fresh **4/4 API boundary**, **7/7 packaging**,
and explicit Release application build/strict signature verification also passed
on this correction. All **29 old named
groups** remain, with **3 additive negatives** retaining the exact former thinking,
incomplete-lifecycle and bare-stop payloads. Valid ordered/empty text remains
accepted; unsupported thinking and malformed lifecycle data fail closed. The
three original failures were captured RED before editing fixtures, without any
production changes. Actual PASS names were deduplicated for overlapping selectors;
direct cancellation remains **50/50 cancelled, 0 success, 0 other**. See
`structured-model-tools.md` for the exact contract decision and evidence.
The first credential-present structured attempt on **2026-10-24 failed** on its
first nonstream request with gateway `outcomeUnknown`; its actual JSONL audit
has one intent and one unknown completion,
and STOP succeeded. The streaming case was **NOT_RUN**. Separate diagnostic
attempts observed underlying `invalidResponse` on the same request path and isolated
`ModelUsage`'s assumption that every response usage value was a nonnegative integer:
the observed shape instead had four integer token/cache counters plus string
`service_tier` (actual string value not retained).

The response-only fix represents `standard`, `priority`, or `batch` as nullable
`ModelUsage.serviceTier`, separate from integer `values`. Initial absence/null is
none; SSE absence/null retains a known tier, identical repeats and late first values
are accepted, and conflicting non-null tiers fail. Counters remain cumulative and
nondecreasing; optional cache counters are not newly required. Other heterogeneous
or nested usage fields remain unsupported and rejected. There is no request-tier
selection or billing feature. Synthetic shape fixtures are not captured responses.
The correction passed independent review. A normal real-provider rerun on
**2026-10-24** passed both nonstream and streaming tool round-trips: each received
`tool_use`, supplied one matching synthetic fixture result, then received nonempty
final text with `end_turn`. Four task starts and credential reads reconcile with
four completed intent/completion pairs in the actual JSONL; both runs stopped.
This proves only the bounded host model-protocol path. Agent/MCP execution, guest
bridge, VM, UI and isolated Keychain CRUD remain **NOT_RUN**. Detailed results are
in `structured-model-tools.md`; the following text-only evidence is historical.

### Earlier text-only evidence

Tested on Apple Silicon / macOS 26.6.2 / Swift 6.3.3:

```sh
swift run ModelTransportChecks
swift run ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/PackagingTests -v
swift build --product MiniSandbox
```

Current prepared-operation review-fix verification: `ModelTransportChecks`: **29 PASS, 0 FAIL, 1 BLOCKED, total 30**, exit **2** because the isolated Keychain CRUD check is blocked at initial creation (`-60008`); update/readback therefore remains unverified here. The original 25 checks are retained, with five additive checks. The new direct-completion cancellation regression first failed **50/50** as success (suite RED: **28 PASS, 1 FAIL, 1 BLOCKED**, exit **1**), then returned actual `.cancelled` task results **50/50**. Prepared cancel/deinit/repeated-cancel probes verify zero dispatch and four held reservations with a fifth `busy` after repeated cycles; valid empty finished responses remain accepted. `ContractChecks`: **7/7 PASS**, exit **0**. A test failure exits 1; a completely passing run exits 0. A name fragment can select one check for diagnosis; an unmatched selector exits 64 rather than reporting success with zero tests. Selection is not a full-suite PASS.

Regression tests first reproduced explicit provider failures being accepted and malformed text blocks being dropped, then passed after the fixes. Both provider failure reasons are separately checked in completion and SSE, including partial output followed by `[DONE]`; positive finish-reason and mixed-block cases also pass.

Prior PR #7 transport-only live smoke **4/4** predates this refactor. The current prepared-operation transport and centralized gateway-time validation were exercised through `HostIntegrationChecks --live` on 2026-10-24: **4/4 PASS**, covering both protocols and completion/streaming with actual F03 approval and JSONL intent/completion. Fixture success alone is not used as external-service evidence.

The centralized-time candidate reran **38/38 host integration**, **17/17 authorization**,
**7/7 contracts**, **4/4 API boundary**, **7/7 packaging**, and the
`MiniSandbox` application build, each exit **0**. The model suite's exit **2**
is retained for Keychain BLOCKED, not converted to PASS.

Gateway time checks now share one validated run-time primitive: run expiry latches
revocation before suspension and takes priority over action expiry; each start
gate compares run/action deadlines using the same sample. Not-yet-valid and
action-only denials are nonterminal. Pre-credential and post-preparation expiry
regressions check immediate revocation and zero additional reads/hits on rollback;
the post-preparation case distinguishes its one prior authorized credential read.
No transport implementation changes were made in this bounded repair.

Transport tests use a URLProtocol fixture with synthetic credentials. They assert the captured request instead of swallowing callback assertion failures, check exact routes and headers, decode validation, real incremental delivery before EOF, Unicode fragments, terminal framing, redirects, cancellation, capacity reuse and request/response limits. These are not real remote service or guest isolation tests.

An opt-in host-only smoke test uses a test credential already placed in the host test process environment:

```sh
swift run ModelTransportChecks --live
```

It requires `TEST_DEEPSEEK_KEY`; it never reads `.env` automatically. It prints only result labels, not the key or model response. Historical PR #7 fixed-endpoint transport-only smoke on 2026-10-23 passed **4/4**. The current centralized-time gateway result is from `HostIntegrationChecks --live` (**4/4**), not a rerun of the transport-only command above. Both smoke paths use a test-only in-memory provider, **not Keychain**, and are not production storage fallbacks. No GUI, VM or Agent verification is implied.

## Transport verification scope

The transport was introduced on foundation PR #4 with design #3. The following results record that transport increment's verification scope.

- S07/S25 transport-level route, redirect and sanitized-error subchecks: covered by fixture tests; current centralized-time gateway/prepared-transport real host calls **4/4 PASS**, separately from those security checks.
- Keychain CRUD in the product's native context: **BLOCKED** as above.
- Authenticated VM/vsock and F10 routing, guest canary isolation (S01), DNS/adversarial network integration, end-to-end stop/revocation, and a complete Agent loop (E03): **NOT_RUN**. The standalone host gateway's dispatch-boundary checks are documented separately and do not establish those integrations.
- Real GitHub/OAuth/MCP integration: **NOT_RUN**; this increment does not call those services.

Provider field reference: DeepSeek's official “Using the Anthropic API” guide (`api-docs.deepseek.com/guides/anthropic_api`).
