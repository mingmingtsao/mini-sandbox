# Actual CLI permission final clock

A CLI permission response is a concrete authorization effect. F03 consumption records intent but does not authorize a later socket write indefinitely. `BusinessVMFrameOutput` therefore retains the grant start and exact pending-action expiry for permission frames. `RunLifecycle.acceptVMFrame` samples its trusted clock after the writer and actual VM connection owner are held, then checks run/connection identity, grant start and the action deadline before each bounded send. Partial/EAGAIN/EINTR retries re-enter this fence. Control/workspace frames cannot supply permission deadlines or action IDs.

This closes a distinct gap from run expiry: an action can expire while its run remains active. The permission connection's continuous lifetime bound is also retained; it cannot replace the approval clock or its high-water wall-time behavior. A permission reply never grants reusable session rules. The normal Claude `permission_suggestions` field, including `setMode: acceptEdits`, is captured as untrusted metadata in the approved request and never applied by the host response.

## Actual VM fixture

`Tests/BusinessVMSecurityChecks/PermissionClockProbe.swift` boots the existing business image with the pinned Claude Code 2.1.309 binary and no NIC or directory shares. It imports a synthetic README through the bound workspace session, captures a real CLI HTTP request, and delivers one fixed synthetic `Write` tool-use response through `ControlledRunOutput` and the actual VZ owner. That response only induces the CLI's normal permission request. The fixture does not fabricate a tool result or invoke a tool itself.

The actual permission frame is parsed with the production parser. A real installed grant and F03 action create the scope and deadline. The bounded writer uses the actual permission connection minted by the VM listener. In negative modes the fixture attempts an `allow` reply and requires zero actual send calls and zero committed bytes. The exact-deadline modes leave the run active, so run expiry or VM shutdown cannot mask an absent action fence. The lock mode holds the actual lifecycle mutex and proves that the worker already holds the concrete writer before advancing time.

| Mode | Observed result |
| --- | --- |
| `expiry` | At the exact action deadline, actionExpired; 0 writes / 0 bytes; run active |
| `lock-expiry` | Concrete writer held while lifecycle contention crosses the deadline; 0 writes / 0 bytes; run active |
| `not-before` | Raw wall time rolls behind grant start while run remains active; 0 writes / 0 bytes |
| `stop` | Run Stop and physical owner retirement prevent any permission write; 0 writes / 0 bytes |
| `deny` | Real 55-byte denial reaches CLI; its next 19,782-byte HTTP request contains the real denied tool result |

All five modes passed. Each first CLI HTTP request was 19,453 bytes; the fixed synthetic tool SSE committed 1,011 bytes through the actual VZ consumer. Every run reported actual stopped state, settled callbacks and deleted private disk. Credential reads and external-provider requests were zero. These are security fixture results, not a genuine provider coding task, GUI approval, or proof that arbitrary guest-reported test results are trustworthy.

An isolated behavioral RED build removes only the final permission not-before/deadline checks from a temporary copy of `RunLifecycle.swift`. The production source remains fixed. The same permanent `expiry` fixture failed with exit 1 after observing one actual send of 118 permission bytes while the run was still active; the expected action denial did not occur. This temporary unsafe binary is a diagnostic artifact, not part of the App or runtime profile.

## Reproduction and evidence scope

Build the standalone entry with the real SandboxHost sources, SandboxContracts objects, package name `MiniSandbox`, Swift 6, and the existing explicit test flags. Sign this test executable with `scripts/vm-probe.entitlements`. The shared `Tools/WorkspaceTransfer/build_host.py` permission-clock mode provides this fixed source selection. Never include test flags or the synthetic tool response in the normal App.

Run `host BUSINESS_IMAGE VENDOR_DISK NEW_PRIVATE_SESSION MODE`. The session directory must already exist, be user-owned mode 0700, have trusted ancestors and have a canonical path; use a new directory for every mode. `/private/tmp` is unsuitable for WorkspaceStore, and Foundation canonicalizes `/private/var` to `/var`, which the VM resource policy rejects. Use a private artifact directory under the user's canonical home path. The fixture validates image/vendor digests, does not modify the input image or vendor disk, and has a 90-second watchdog plus actual VM cleanup.

The verified image initramfs was `e056dad63b978081d86f394198ef1b5810f990d4167bde3b2a1b0b6b4681e469`; vendor disk `c4e512ea944c420c80285b4c4bd817098d9845ac6aa6e423bbbb58b8d3a9bf43`; pinned CLI binary `028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332`. Counts are not claimed for another image, CLI or source revision without rerunning it.

The initial real permission capture failed closed because the pinned CLI added `display_name` and `description`; a Bash capture also contained `decision_reason_type`. The parser repair admits bounded presentation strings and retains them in the approval envelope, while preserving strict unknown-field rejection. This failure was not treated as a successful tool loop. Original source files remain unchanged, and no normal test expectation was weakened.
