# Bounded workspace copy, review, and new-directory export

`WorkspaceStore` is a synchronous, caller-serialized host API for bounded
regular-file trees. It imports data into a private baseline and writable working
copy, produces an add/change/delete review, and exports an explicitly reviewed
version to a new directory. It never overwrites the original tree and never
executes imported or edited content.

This is a filesystem/data-model slice, not a completed end-to-end product feature.
There is no selection UI, VM transfer, guest protocol endpoint, Agent integration,
CoW implementation, or full S20/S21 acceptance claim. Future VM transfer and guest
protocol wiring require their own boundary validation; these module checks do not
establish safety of those integrations.

## API and data ownership

- `WorkspaceStore(newRoot:limits:cancelled:didReadChunk:)` exclusively creates a
  managed root. Existing roots cannot be attached. Instrumentation callbacks are
  trusted host diagnostics, not guest input or executable content.
- `importTree(from:)` accepts a selected absolute directory. The returned snapshot
  contains a process-local opaque handle, working-directory path, SHA-256 file
  manifest, and reported exclusions. Directories have no file hash.
- `review(_:)` compares the working copy with private immutable baseline values.
  It returns sorted additions, changes, and deletions, manifests, and before/after
  previews. Directories, binary/control-bearing data, and oversized content have
  explicit no-preview reasons; no claim of human review of every byte is made.
- `originalChanges(_:)` reports changes separately against that same baseline.
  Original changes do not replace the baseline. Errors are not “unchanged.”
  Excluded contents are not read, so changes inside them cannot be reported.
- `exportReviewed(_:toNewDirectory:)` requires an owner-bound review, verifies the
  working tree again, materializes a private staging directory, verifies its
  contents, and promotes it with `renameatx_np(RENAME_EXCL)`.

The read-only on-disk baseline uses directory mode `0500` and file mode `0400`;
working/export directories use `0700` and files `0600`. The authoritative baseline
is private in-memory data, not a later reread of a mutable disk baseline. Handles
cannot be transferred between stores. Aggregate multi-snapshot storage quotas,
retention/lifetime management, and persistent restoration are not implemented.

## New-node metadata policy

Copying is data-only, not a metadata-preserving whole-tree copy. Source ACLs,
xattrs, executable bits, and permissions are not propagated. The `.git` exclusion
includes its configuration and hooks; ordinary scripts are copied only as data.
Production code does not read source xattr values. Source and ancestor permissions
are never changed.

Only exclusively created destination nodes are sanitized: their inherited ACL is
cleared, restrictive mode is applied, and effective-user ownership, exact mode,
and empty ACL are verified. `ENOENT` from Darwin extended-ACL lookup means no ACL;
other lookup/enumeration errors fail closed. Darwin's ACL enumeration convention
is used rather than assuming Linux/POSIX return semantics.

Fresh destination nodes may already carry `com.apple.provenance` before copying
source data. That specific OS-created name is retained; its value is neither read
nor removed. Absence is also allowed. Any other xattr on a fresh node causes a
platform-policy failure. This is an explicit narrow allowance, **not a zero-xattr
claim**, and it does not imply a known reason for the OS marker's behavior or
preservation of the source's quarantine/Gatekeeper provenance.
No attempt is made to remove OS security markers. Metadata canary tests verify
that a synthetic source-only attribute and source ACL stay on the original and do
not propagate, while observed fresh-node provenance remains present.

## Filesystem boundary and concurrency assumptions

The OS, application, and caller are trusted. Untrusted file data is not trusted to
provide paths, permissions, executable instructions, or authority. A compromised
same-UID host process or root can defeat filesystem checks; this API does not claim
atomic resistance to such an actor. This does not grant guests direct host access
or relax validation of guest-produced data.

Before creation, destination ancestors must be root/effective-user owned with no
group/world write bits. ACL ALLOW entries are conservatively refused, even if they
appear harmless; DENY-only ACLs are permitted and remain unchanged. No ancestor
ACL or mode is “repaired” to make a write succeed.

Paths are traversed component-by-component with no-follow directory descriptors.
Nodes are classified before opening and checked again after nonblocking open.
Regular files must have one link; links, FIFOs, sockets, devices, and other special
nodes are refused. Two bounded scans compare content plus descriptor/entry
identity and mutation stamps. Writes use exclusive creation.

The recorded original pathname stays forbidden for export even if its inode has
changed. Descriptor ancestry checks also prohibit export beneath original or
managed roots. Original, managed, working, staging, and destination-parent
bindings are revalidated at the relevant read/write/commit boundaries. Observed
relocation or replacement causes failure; repeated checks are not an atomic
namespace lock. Trusted callers must serialize operations and must not move or
modify managed/export namespace components during an operation.

New excluded entries in the working copy are reported by review but prevent
export with `excluded working entries require selection`, including entries
observed during staging. They are not silently omitted or reported as a generic
stale review. Selection UI is required before supporting such exports.

Cancellation or pre-commit failure does not publish the requested new directory.
Exclusively created incomplete staging directories may remain for host inspection.
Unknown objects are never recursively cleaned up, including a destination created
concurrently by another actor. A rename collision preserves that destination.
After successful rename, verification/sync errors use `committedUnverified`:
publication may already have occurred, and callers must not say “nothing was
written” or blindly retry/clean up. Success means publication and directory sync
completed; it is not a GUI-level confirmation.

## Bounds and exclusions

Defaults: 1,000 entries; 4 MiB per file; 16 MiB included content per tree; depth 16;
1,024 UTF-8 bytes per relative path; 4,096 bytes per preview. Configuration has hard
upper bounds. Excluded entries count toward the entry limit, but their subtrees
are not entered. Names must be UTF-8 NFC, at most 255 bytes per component, without
traversal, slash, backslash, colon, NUL, or control characters. Case-folded
collisions are refused. Lexical NFC comparisons use bytes, not Swift's
canonical-equivalence string equality.

Known credential names and configuration patterns (including `.git`, `.ssh`,
`.env` variants, and selected key-file suffixes) are reported and excluded before
content opening. This reduces exposure; it is not universal secret detection or
redaction. Secrets embedded in ordinary included files may remain.

## Checks

Run from the package root in an environment with a private, non-world-writable
`TMPDIR` and trusted ancestors:

```sh
swift run WorkspaceChecks
swift run WorkspaceChecks --self-check-failure  # expected exit 1
swift run AuthorizationChecks
swift run ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/PackagingTests -v
python3 scripts/build-app.py
codesign --verify --strict --verbose=2 dist/MiniSandbox.app
```

The commands above run workspace checks in Debug. The packaging script builds
the explicit `MiniSandbox` product in Release; this is not generic Release
all-targets validation. Workspace checks print named groups and assertion counts
and propagate failures.
Negative cases assert specific errors, so an unrelated platform failure cannot
masquerade as rejection coverage. Fixtures are synthetic; no device creation,
privileged commands, real credentials, or original project imports are required.

Coverage includes the positive import/edit/review/export path; source metadata
canaries; restrictive destination modes; original preservation and immutable
baseline; unsafe ancestor modes/ACLs; observed namespace changes; exclusions;
foreign/stale handles; symlinks/hardlinks/FIFO/socket; byte/count/depth/path/aggregate
bounds; text/binary/oversized previews; no execution; cancellation after staging
begins; and concurrent destination creation. Device rejection is a pure test of
the production stat classifier, **not a real-device creation test**. On a
case-insensitive filesystem, duplicate case names are refused by the filesystem;
the production name classifier is also exercised directly. A case-sensitive
filesystem can additionally exercise the full duplicate-entry scan branch.

Post-rename failure semantics are implemented but do not yet have deterministic
fault-injection coverage. Build/signature checks do not establish notarization,
GUI behavior, VM behavior, or independent security approval.
