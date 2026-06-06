# Resource-fork sync for on-demand files (FileProvider)

**Date:** 2026-06-06
**Status:** Approved design, pre-implementation
**Scope:** macOS FileProvider (on-demand) upload/download only

## Problem

A macOS file can carry two data streams: the **data fork** (normal content) and
the **resource fork** (`<path>/..namedfork/rsrc`, also surfaced as the
`com.apple.ResourceFork` xattr), plus **FinderInfo** (`com.apple.FinderInfo` —
the 32-byte type/creator record). Classic Mac files — almost exclusively old
fonts (Linotype suitcases, `.suit`, `.fam`, `.t1`, `.bmap`, `FFIL`, …) — store
their actual content in the resource fork with a **0-byte data fork**.

SyncVault's FileProvider upload reads only the data fork, so these files upload
as 0 bytes and their real content (resource fork + type/creator) is lost. This
surfaced as ~20k "0-byte" font files in the user's `Toolbox/Fonts` library.

**Out of scope / known limitation:** the *existing* library cannot be recovered
— its resource-fork content is gone both locally (dataless placeholders, rsrc=0)
and on the server (0-byte uploads, no non-zero version). This feature protects
**files added or modified going forward** only.

## Goals

- A resource-forked file added to / modified in the on-demand folder uploads
  with its full content (data fork + resource fork + FinderInfo) preserved.
- Materializing (downloading) such a file restores both forks + FinderInfo so
  the file works (e.g. a classic font installs correctly).
- No regression for normal (data-fork-only) files — they stay on the fast path.
- No server change. No re-upload loop.

## Non-goals

- Recovering the existing damaged library (impossible — content is gone).
- The backup sync engine (`SyncEngine.swift`) — it has the same data-fork-only
  limitation but is out of scope here; tracked as a follow-up.
- Web UI awareness of AppleDouble blobs (a packed file downloaded via the web
  app is an AppleDouble archive, not the raw file — acceptable for this niche;
  possible future enhancement).

## Approach: AppleDouble blob via `copyfile(3)`

Use the macOS system primitive `copyfile(3)` with `COPYFILE_PACK` /
`COPYFILE_UNPACK`. PACK serialises {data fork, resource fork, FinderInfo,
xattrs} of a file into a single AppleDouble byte stream; UNPACK reverses it.
This avoids a hand-written AppleDouble encoder and is the OS's own format.

The packed stream is uploaded as the file's normal content. Detection on the way
back uses the AppleDouble **magic number** in the first 4 bytes
(`0x00 0x05 0x16 0x07`), so the server needs no flag and stays a dumb byte store.

### Trigger (narrow)

Pack **only** when the source file's resource fork is non-empty
(`getxattr(com.apple.ResourceFork)` length > 0, or the `..namedfork/rsrc` size >
0). Normal files (no resource fork) take the existing kale data-fork path. PACK
includes FinderInfo + xattrs automatically, so we do not need to trigger on
FinderInfo alone.

### Upload — `createItem` and `modifyItem` (FileProviderExtension.swift)

1. Determine if `url` has a resource fork (helper `hasResourceFork(url)`).
2. If yes: `packed = AppleDoubleCodec.pack(url)` →
   `copyfile(url, packed, NULL, COPYFILE_PACK | COPYFILE_DATA | COPYFILE_METADATA)`
   into the extension temp dir. Upload `packed`'s bytes via the existing raw-PUT
   `uploadFileFromDisk`. Delete `packed` after.
3. If no: upload `url` as today.
4. The 0-byte guard measures the bytes actually being uploaded (the packed file),
   which is > 0 for a resource-forked file, so no false rejection. `createItem`
   has no guard (new file).

### Download — `fetchContents` (FileProviderExtension.swift)

1. Download bytes to a temp file as today.
2. Peek the first 4 bytes. If they equal the AppleDouble magic
   (`00 05 16 07`): `final = AppleDoubleCodec.unpack(tmp)` →
   `copyfile(tmp, final, NULL, COPYFILE_UNPACK | COPYFILE_DATA | COPYFILE_METADATA)`
   and return `final` (both forks + FinderInfo restored).
3. Else: return the temp file as-is (today's behaviour).

### Change detection

The uploaded bytes of a packed file **are** the AppleDouble (resource fork
included), so any fork change yields different bytes → different server content
hash → the server's `/api/files/put` creates a new version. No extra logic.

### The risk to verify with tests

A round-trip must not cause a re-upload loop: after a resource-forked file is
materialised locally (data + resource fork present), macOS must not consider it
"changed" versus the server. `itemVersion.contentVersion` is the server content
hash (of the packed bytes) and is stable across enumerations; we never re-upload
on materialise. The end-to-end test below is the gate that proves this.

## New component

`macos/FileProvider/AppleDoubleCodec.swift` — a small, focused helper:

- `static func hasResourceFork(_ url: URL) -> Bool`
- `static func pack(_ url: URL) throws -> URL` (returns temp AppleDouble file)
- `static func unpack(_ url: URL) throws -> URL` (returns temp reconstructed file)
- `static func isAppleDouble(_ url: URL) -> Bool` (4-byte magic check)

It depends only on `copyfile(3)` (libc) and `Foundation`. It does not know about
the API client, cache, or FileProvider types — pure file→file transforms,
independently testable.

## Testing

1. **Codec unit tests** (fixture-based):
   - Build a fixture file with a known resource fork (write via
     `setxattr(com.apple.ResourceFork)` or a checked-in classic font fixture).
   - `pack` → assert output begins with the AppleDouble magic and is non-empty.
   - `unpack` the packed file → assert data fork and resource fork bytes match
     the original exactly (round-trip identity).
   - `isAppleDouble` true for packed output, false for a plain text file.
   - `hasResourceFork` true for the fixture, false for a plain file.
2. **Guard regression:** a genuinely empty file (0 data, 0 resource) is NOT
   packed and uploads as 0 bytes without rejection.
3. **End-to-end (scripted against the dev account), the loop gate:**
   - Place a resource-forked file in the on-demand folder → confirm the server
     stores a non-zero AppleDouble (size > 0, content starts with magic).
   - Evict → re-open (materialise) → confirm both forks restored and the file
     is usable.
   - Watch logs for ~60s: **zero** repeated modifyItem/upload for that file
     (no re-upload loop).

## Rollout

Client-only change → ships in the next macOS app release (3.6.0) per the
release checklist (all version files bumped together). No server deploy.
