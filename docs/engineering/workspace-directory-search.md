# Workspace ancestor search descriptors

Workspace paths are still opened one component at a time relative to retained
directory descriptors. Intermediate ancestors now use `O_SEARCH`, with
`O_NOFOLLOW`, `O_CLOEXEC` and `O_NONBLOCK`. Before/after `fstatat`/`fstat` identity
checks, directory classification, path grammar, uid/mode/ACL checks, root
containment and namespace revalidation are unchanged.

The access modes are deliberately separate:

- `openDirectory` uses search-only ancestors and an `O_RDONLY` final selected tree.
- A new root/export destination's parent is only traversed, checked and used for
  relative operations, so its descriptor is search-only too. Exclusive creation,
  publication, post-publication verification and directory fsync still execute.
- `trustedAncestors` and `isWithin` use search-only `..` descriptors. Leaving those
  calls as `O_RDONLY` would still request ancestor directory reading later.
- Ordinary child files/directories and `scan`/`fdopendir` retain normal read access.
  Newly created managed directories retain their existing sanitization/read opens.

Apple documents `O_SEARCH` as directory search access, while `O_EVTONLY` is intended
for change notifications; the latter is not used. The published XNU authorization
path maps search mode to directory search permission and still invokes the MAC
open check. No failed search open falls back to a broader mode, skips validation
or changes permissions. See Apple's [open(2)](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/open.2)
and [vnode open authorization](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_subr.c#L7859).

This change follows access to the user-selected tree without asking to list its
ancestors. It does not grant access to the tree, suppress system consent, modify
TCC, add entitlements or authorize access denied by macOS. Apple explains that
file consent can block the calling thread and that standard Open/Save interactions
establish user intent in [WWDC19 session 701](https://developer.apple.com/videos/play/wwdc2019/701/).
A command-line POSIX permission test is not a TCC result for a packaged App.
Actual App/NSOpenPanel behavior must be verified separately under that App's own
identity and consent state; final tree/content access may still be denied.

## Regression evidence

The new Swift test first ran against unchanged production traversal. Its owned
ancestor permitted search/write but denied directory read. The direct descriptor
control passed; real `WorkspaceStore` then failed with `EACCES` (exit 1). After the
change the same test imports, reviews and exclusively exports through that parent,
leaving source bytes and parent permissions unchanged. Six companion groups check
descriptor identity, unreadable selected trees/files, absent search permission,
symlinks and an ancestor renamed during an actual content read.

On macOS 26.6.2, uid 501, the full `WorkspaceChecks` passed 34 named groups / 187
assertions, including all prior mode/ACL, containment, collision and mutation
checks. The existing `WorkspaceTransferChecks` also passed all 137 unique cases,
including run/clock/cancel/write/adoption/publication fences. The standalone C
probe checks 12 permission/descriptor behaviors,
including inability to enumerate a search-only descriptor (`EBADF`) and preserved
ACL metadata access; it also reports the filesystem's `fsync` result. This is
local-filesystem evidence, not a claim about every filesystem or supported OS.

Reproduce without accessing protected user folders:

```sh
clang -Wall -Wextra -Werror Tests/WorkspaceSearchChecks/open_search.c -o /private/tmp/mini-sandbox-open-search
/private/tmp/mini-sandbox-open-search
swift build --product WorkspaceChecks
swift run --skip-build WorkspaceChecks --search-only
swift run --skip-build WorkspaceChecks
swift build --product WorkspaceTransferChecks
swift run --skip-build WorkspaceTransferChecks
```

Use a canonical, user-owned `TMPDIR` accepted by the existing ancestor policy.
The C probe exclusively creates its own `/private/tmp` fixture and cleans it up;
Swift fixtures live below `TMPDIR`. No protected Documents/Desktop tree, foreign
user identity, system settings or permission database is used by these probes.
