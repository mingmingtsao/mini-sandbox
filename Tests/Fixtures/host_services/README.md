# Host loopback fixtures

This directory contains executable local test services for future real Host Core/Broker integration. It has no production Broker and no policy gate pretending to validate Broker enforcement.

## Run

From the repository root:

```sh
python3 -m unittest discover -s Tests/Fixtures/host_services -v
python3 Tests/Fixtures/host_services/host_services.py
```

The module starts two independent HTTP origins on random ports, both bound to exact `127.0.0.1`. Both origins require exactly one `Host` header matching their host and port, including for unsupported methods. Missing, duplicate, foreign, or alias Hosts return 400. Unsupported verbs (including arbitrary verbs such as `BREW`) return 405 with a valid Host; HEAD responses have no wire body. Supported request bodies are bounded, JSON duplicate keys are rejected, and transcripts omit headers, bodies, and query strings. Default request-line logging is suppressed. No real credentials are used.

The exported `HostFixture.start()` / `start_fixture()` handle exposes `auth.origin`, `resource.origin`, and `control`. `control.reset()` clears redacted transcripts and resource request counts. The counter measures parsed HTTP requests reaching method dispatch, once per request and before authentication, application validation, or response. It includes unsupported verbs, Host failures, malformed application bodies, and disconnect faults; it is not a TCP arrival counter. Request-line/header parser failures, empty connections, and incomplete traffic rejected before dispatch are excluded. A transcript status can remain null when no response is sent. `set_fault(service, mode)` supports `401`, `500`, `connection_close`, `timeout`, and `write_then_disconnect` for resource writes. The latter commits the in-memory write before closing, so clients can test an unknown result without replaying blindly.

The simulated OAuth client is `fixture-client` with registered redirect URI `http://127.0.0.1/callback`. It provides authorization metadata, exact redirect/resource binding, S256 PKCE, state echo, single-use authorization codes, expiring bearer access tokens, HTTP family revocation (`/oauth/revoke`), and single-use refresh rotation. The broad fixture grant intentionally permits repositories A and B and writes to both, proving upstream baseline behavior before a real Broker is inserted.

MCP uses fixed protocol version `2025-03-26` and implements `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `resources/list`, and `resources/read`. `repo_write` intentionally advertises `readOnlyHint: true` so callers cannot treat that hint as an authorization decision.

## Current verification and limits

Verified locally with `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Fixtures/host_services -v`: 23 tests ran and passed (`OK`) using Python stdlib and real loopback sockets. Coverage includes metadata, OAuth lifecycle/error cases, MCP reads/writes, body/key limits, faults, reset, transcript token/body/query redaction, and refusal of `0.0.0.0` startup. Raw-socket regressions verify GET and PUT reject `/v1/repos/../B` and `/v1/repos/%2e%2e/B` (and other tested aliases) without changing either repository, HEAD has no wire body, and unsupported verbs follow exact Host policy and count once. A direct bearer-audience negative changes only a fixture-issued token record under the test's state lock and verifies 401; it does not merely test token issuance rejection. A malformed request-line test verifies exclusion from the counter, while malformed JSON after HTTP parsing is counted. Standalone CLI startup, separate loopback origins, health/metadata responses, and SIGINT shutdown were also rerun successfully (exit 0).

This fixture implements a fixed, stateless JSON HTTP subset, not full HTTP/OAuth/MCP conformance or exhaustive malformed-input coverage (SSE/resume/session interoperability is NOT_RUN). Loopback is host-only reachability, not authentication between processes on the same host; do not expose it through guest routes or forward arbitrary guest URLs.

The actual Swift Host Core/Broker and VM integration is `NOT_RUN`: Broker resource denial, action replay/unknown-result handling, and guest networking fail-closed behavior require the real Host Core/VM. External service interoperability is `NOT_RUN`. No Swift build or external service was used. The counter has not yet been validated as evidence through the real Broker, and these local tests are not independent review approval. No fixture result claims those controls passed.

Future Broker integration should start `HostFixture`, grant only the test workload's intended capability through the real Host Core, route the guest through its actual Broker, then assert upstream hit counts/transcripts and reset them through `fixture.control` between cases. The fixture baseline must remain broad so a Broker denial test proves the Broker blocked an upstream capability that works directly.
