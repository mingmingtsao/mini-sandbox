# Pinned Claude MCP client and local repository adapter

The observed Claude Code 2.1.309 client sends `server/discover` using MCP
`2026-07-28`. It carries version, client information and capabilities in
`params._meta`, with HTTP method/version/name mirrors. The initial captured
request body was 458 bytes. This is a separate adapter from the existing
`fixture-repository-v1` protocol and its `2025-03-26` initialization handshake.
Client information is compatibility data; the actual installed VZ socket owner
provides the run identity.

The [current protocol](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
has stateless discovery rather than an `initialize` session. The adapter supports
only `server/discover`, `tools/list` and `tools/call`, with numeric or bounded
string request IDs, JSON responses, and complete text tool results. It advertises
only tools. SSE, subscriptions, pagination, caching, input-required results,
arbitrary schemas and legacy sessions are not advertised or passed through.
Unsupported fields, paths, HTTP framing, mirror mismatches and methods fail closed.

`HostMCPConnection.claudeLocalRepository` selects a literal host-loopback
`POST /mcp` service and a host credential provider. The product does not execute a
third-party host command or accept a guest-selected upstream URL. Its fixed
repository adapter recognizes `repo_read` and `repo_write`, resolves resources
`A` or `B` from exact typed arguments, and requires grant permission for `A`.
Even the deliberately misleading write-tool `readOnlyHint` cannot grant access.
The local test server itself permits both resources, so its larger policy does
not substitute for host enforcement.

## App integration

1. Select the local connection and include its real account/route versions and
   explicit `mcp` scopes in the immutable run grant. Control operations are
   `server/discover` and `tools/list`; resource `A` has `read` and optionally
   `write`. The start frame selects `mcp=true` only for a configured connection.
2. Parse actual service-4066 HTTP using `ClaudeMCPIngress`. Call
   `proposeVMClient` with that parsed request and the exact listener-minted
   `BusinessVMConnection`. The complete approval envelope includes protocol
   selectors, payload, account/route/catalog bindings, runtime ID and channel ID.
3. Present `proposal.pendingAction` in the native approval flow. A denial retires
   that request's VM connection. Approval is consumed once through the existing
   authority. Tool execution remains the actual CLI's responsibility.
4. Construct `makeVMNativeOutput` from the same owner, then call the controlled
   `execute(..., output:)` overload and drain `acceptNext()` until an actual final
   response is committed. The modern adapter rejects raw/no-consumer execution.
   A returned producer call is not proof that the peer received its bytes.
5. Stop/revoke/cancel uses the existing composition and shared lifecycle. The
   upstream resume and each final guest send retain concrete VM ownership before
   the lifecycle clock fence. Partial writes and backpressure retry that gate.

The catalog is frozen once learned. An identical refresh is accepted; a changed
catalog invalidates the connection and requires a fresh host configuration/run.
The adapter does not silently adopt changed tool semantics under old approvals.

Returned JSON-RPC IDs and result/error envelopes are checked before output.
Credential reflection checks cover the exact credential's canonical literal
spelling, decoded JSON keys/scalars and joined text items before any peer byte.
This is bounded exact matching, not general encoded-secret or steganography
detection. No credential is given to the guest or logged by the fixture.

## Local verification

```sh
swift build
python3 Tests/MCPGatewayChecks/claude_loopback.py .build/debug/MCPGatewayChecks
```

The driver creates its own literal-loopback server and random fake bearer in
memory. It verifies nine phases against actual upstream arrivals and a real
AF_UNIX HTTP consumer: discovery, read A, denied read/write B and denied write A,
one approved write with replay refusal, exact/split credential reflection with
zero output, wrong request ID with zero output, a legal JSON-RPC error, and Stop
before final output. It requires the final marker and exactly one upstream write;
early process exit is failure. The test-only local-consumer factory is absent
from a normal Release build.
