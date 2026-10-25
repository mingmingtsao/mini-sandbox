# Application virtualization signing

`scripts/build-app.py` signs the actual `MiniSandbox.app` executable with the
dedicated `scripts/app.entitlements` file. Its only entitlement is
`com.apple.security.virtualization = true`; the separately signed diagnostic
`VMProbe` is not used as evidence for the application's entitlement.

Reproduce a normal optimized application build and inspect the final signature:

```sh
python3 scripts/build-app.py --configuration release --sign-identity -
codesign --verify --strict --verbose=2 dist/MiniSandbox.app
codesign -d --entitlements :- dist/MiniSandbox.app
```

The packaging regression verifies that the application signing invocation uses
this entitlement file and verifies the same staged bundle before promotion.
Existing ownership checks and backup preservation still apply. A failed signing
or verification step does not replace the previous application.

Local validation on macOS 26.6.2 / Apple Silicon / Swift 6.3.3 built a normal
Release application, verified its signature, and read the virtualization
entitlement from that application's signature. The default `-` identity uses
ad-hoc signing for local execution.
