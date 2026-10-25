# Fixed host model transport

## Scope

This increment implements a host-only, text-only DeepSeek transport in `SandboxHost`. It is package-visible, has no guest listener, and does **not** grant permission to call a service. The future Broker must connect an authenticated run, a live authorization decision, and its dispatch boundary before using it.

The allowlisted model is `deepseek-flash`. Structured requests select only the OpenAI-compatible or Anthropic-compatible protocol; there are no caller-supplied URLs or HTTP headers. The two routes are fixed to `https://api.deepseek.com/chat/completions` and `https://api.deepseek.com/anthropic/v1/messages`. Host credentials are added in the corresponding authentication header. Anthropic system instructions are carried in the `system` field, not discarded. This text-only increment explicitly disables thinking and does not implement tool calls, image inputs, Agent adapters or MCP.

The default session is ephemeral, does not use cookies or a response cache, refuses redirects, and uses finite request/resource timeouts (60/120 seconds). Error messages report bounded categories/status codes, not upstream response bodies or credentials. Requests are not retried automatically. Injected `URLSessionConfiguration` is a trusted package-level test seam, never a protocol field exposed to guests.

## Bounds and streaming

- At most 128 messages; each message is nonempty and at most 64 KiB UTF-8. Output limit is 1–8192 tokens. Decoding calls the same validating constructors.
- At most 1 MiB encoded request, 4 MiB response and 256 KiB per SSE line.
- Four active requests per transport instance; excess requests fail immediately with `busy`. Cancellation and every exit path release the slot.
- Text chunks are delivered before EOF. SSE supports UTF-8 fragments, LF/CRLF/CR, comments and metadata fields, OpenAI `[DONE]`, and Anthropic lifecycle/`message_stop` events. EOF without a framed terminal event is an error. Non-text metadata is not represented as text output.
- The URLSession task is cancelled when the caller cancels or processing exits, including rejection and size-limit errors.

OpenAI-compatible completion and SSE responses reject explicit `finish_reason` values `insufficient_system_resource` and `aborted` as `providerFailure` (`upstream generation failed`), even with HTTP 200 and partial text. No body, credential, or raw provider error is included. A failed SSE event emits neither its own text nor a success-final marker; previously delivered partial chunks cannot be retracted, and the consumer must handle the terminal error. A later `[DONE]` does not override the failure.

Other finish reasons retain the text-only behavior: `stop`, `length`, `content_filter`, and `tool_calls` preserve any supplied string text, rather than becoming provider failures. This does not guarantee an untruncated/unfiltered answer or execute tools. Missing/null finish reasons remain compatible; unknown reasons are not interpreted. SSE still requires a framed `[DONE]` for successful termination, not merely a finish reason.

Every Anthropic `type: text` completion block requires string `text` (including an allowed empty string); missing, null, or non-string text rejects the entire completion as `invalidResponse`. Non-text blocks are separately treated as metadata and ignored. JSON decoding failures in either completion protocol also return sanitized `invalidResponse`, not `network`.

## Credential storage

`KeychainModelCredentialProvider` uses generic-password items scoped by service/account (default `dev.mini-sandbox.model` / `deepseek`), with update and delete operations. It requests noninteractive access and does not fall back to disk or guest environment variables. Storage errors preserve only a numeric OSStatus. Test accounts use random names and disposable values and attempt cleanup. The isolated test checks create/read, a second `setCredential` and update readback, then delete/missing; authorization failure still marks the entire check BLOCKED, not PASS.

**Real Keychain CRUD is currently BLOCKED in the tested CLI context:** `SecItemAdd` returned `-60008` (authorization unavailable). A separate disposable-item probe reproduced that result. Read-only Keychain reachability from the foundation is not evidence that credential storage works. A signed native probe was also built, but LaunchServices could not launch it from the private test location (permission denied), so no application-context CRUD result was obtained. Native application-context validation remains BLOCKED; do not treat the provider implementation as a passed storage integration.

## Reproduction and evidence

Tested on Apple Silicon / macOS 26.6.2 / Swift 6.3.3:

```sh
swift run ModelTransportChecks
swift run ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/PackagingTests -v
swift build --product MiniSandbox
```

Final review-fix verification: `ModelTransportChecks`: **24 PASS, 0 FAIL, 1 BLOCKED, total 25**, exit **2** because the isolated Keychain CRUD check is blocked at initial creation (`-60008`); update/readback therefore remains unverified here. `ContractChecks`: **7/7 PASS**, exit **0**. A test failure exits 1; a completely passing run exits 0. A name fragment can select one check for diagnosis; an unmatched selector exits 64 rather than reporting success with zero tests. Selection is not a full-suite PASS.

Regression tests first reproduced explicit provider failures being accepted and malformed text blocks being dropped, then passed after the fixes. Both provider failure reasons are separately checked in completion and SSE, including partial output followed by `[DONE]`; positive finish-reason and mixed-block cases also pass.

Final-tree regression verification also passed **4 API boundary tests, 7 packaging tests**, and the application build. The opt-in live transport smoke below was rerun against the corrected transport and passed **4/4**.

Transport tests use a URLProtocol fixture with synthetic credentials. They assert the captured request instead of swallowing callback assertion failures, check exact routes and headers, decode validation, real incremental delivery before EOF, Unicode fragments, terminal framing, redirects, cancellation, capacity reuse and request/response limits. These are not real remote service or guest isolation tests.

An opt-in host-only smoke test uses a test credential already placed in the host test process environment:

```sh
swift run ModelTransportChecks --live
```

It requires `TEST_DEEPSEEK_KEY`; it never reads `.env` automatically. It prints only result labels, not the key or model response. Actual fixed-endpoint transport smoke on 2026-10-23 passed **4/4** (OpenAI and Anthropic, completion and streaming). This uses a test-only in-memory provider, **not Keychain**, and is not a production storage fallback.

## Dependencies and outstanding acceptance

Stacked on foundation PR #4 and dependent on candidate design #3; keep Draft pending design approval. This is only the transport increment, not completion of the model/Agent feature.

- S07/S25 transport-level route, redirect and sanitized-error subchecks: covered by fixture tests; real host model calls separately verified.
- Keychain CRUD in the product's native context: **BLOCKED** as above.
- Authenticated VM/vsock routing, authorization-to-network atomic dispatch, guest canary isolation (S01), DNS/adversarial network integration, stop/revocation of in-flight work, and a complete Agent loop (E03): **NOT_RUN**.
- Real GitHub/OAuth/MCP integration: **NOT_RUN**; this increment does not call those services.

Provider field reference: DeepSeek's official “Using the Anthropic API” guide (`api-docs.deepseek.com/guides/anthropic_api`).
