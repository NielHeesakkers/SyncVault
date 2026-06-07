# Migrate SyncVault off GitHub → Codeberg (fully)

**Date:** 2026-06-07
**Goal:** Zero dependency on GitHub. Code, CI, container registry, and the macOS
app's auto-update feed all served from Codeberg.

## Decisions (made with Niel)

- **CI + container registry:** Forgejo Actions on Codeberg, image pushed to the
  Codeberg container registry (`codeberg.org/nielheesakkers/syncvault`).
  **Use Codeberg's HOSTED Forgejo Actions runner** (open alpha, limited resources
  — fine for a small Go arm64 image built ~monthly). No daemon to maintain.
  Fallback only if the alpha proves too constrained: a self-hosted Forgejo runner
  on the Mac mini.
- **App update feed:** Codeberg. `version.json` via Codeberg raw; the `.dmg`/`.zip`
  via Codeberg Releases.

## Feasibility (verified 2026-06-07)

- Codeberg container registry: operational (people push/pull images in 2026).
- Forgejo Actions: available on Codeberg with a self-hosted runner; Codeberg's own
  hosted runners are limited (security + maintainer bus-factor).
- Codeberg Releases with attachments: supported (dmg ~3.8 MB, well within limits).
- Codeberg pull-mirrors: DISABLED site-wide (already learned) — irrelevant now;
  we push, not pull.

## Current GitHub touchpoints (audit)

1. Git host: `origin` = github.com/NielHeesakkers/SyncVault. (Codeberg mirror exists.)
2. CI: `.github/workflows/docker-publish.yml` → builds + pushes `ghcr.io/nielheesakkers/syncvault` on push/tag.
3. Registry refs to `ghcr.io/...`: `docker-compose.yml`, `docker-compose.portainer.yml`, `README.md`, **and the Mac mini deploy compose** `/Users/server/Docker/SyncVault/deploy/docker-compose.yml`.
4. App auto-update — `macos/Sources/SyncVault/UpdaterService.swift`:
   - line 44: `versionURL = https://raw.githubusercontent.com/.../main/version.json`
   - line 144: dmg = `https://github.com/.../releases/download/v{V}/SyncVault-{V}.dmg`
   - `version.json` `dmg_url` field also points at GitHub releases.
   - `docs/appcast.xml` appears UNUSED by the custom updater (Sparkle feed not wired) — confirm, then drop.
5. Cosmetic: README badges/links. Go module path `github.com/NielHeesakkers/SyncVault` (pure identifier — compiles regardless of host; leave it).

Not in scope: third-party SwiftPM deps (Sparkle, SQLite.swift) live on github.com
as upstreams — we're consumers, not hosting them.

## THE critical constraint — don't orphan the auto-updater

The installed app (3.6.2) checks the two **GitHub** URLs above. If GitHub goes
away before the app is taught the new URLs, every installed copy stops updating
and its download link 404s. Therefore the URL switch must ship through ONE LAST
GITHUB RELEASE, and only after that release is installed may GitHub be retired.

## Phased plan (in order)

### Phase 1 — Codeberg CI + registry (no app changes)
1. Re-stage the Codeberg token (file `~/.codeberg-token`, deleted after). Scopes needed: `write:package`, `write:repository`, `read:user`.
2. Enable Actions on the Codeberg repo (repo Settings → Actions). Opt the repo into Codeberg's **hosted** Forgejo Actions runner (open alpha). Create a Forgejo Actions **secret** with a Codeberg package-write token for the registry push.
3. Add `.forgejo/workflows/docker-publish.yml` (port of the GH workflow): build linux/arm64, push to `codeberg.org/nielheesakkers/syncvault:latest` + `:vX.Y.Z`. Runs on the Codeberg hosted runner (label `docker`/`ubuntu-latest` per Codeberg's runner).
4. Verify: a push to Codeberg triggers the workflow → image appears in the Codeberg container registry. Make the package **public** (so the mini pulls without auth).
5. Fallback (only if the hosted alpha is too constrained): register a self-hosted Forgejo runner on the mini and re-run.

### Phase 2 — Server deploy off ghcr
6. Update the **mini deploy compose** to `image: codeberg.org/nielheesakkers/syncvault:latest`; `docker pull` + recreate; verify `/api/health` 3.6.2 + storage_ok.
7. Update repo compose files + README image refs to the Codeberg image.

### Phase 3 — App update feed → Codeberg (the bridge release, 3.7.0)
8. Change `UpdaterService.swift`:
   - `versionURL` → `https://codeberg.org/NielHeesakkers/SyncVault/raw/branch/main/version.json`
   - dmg URL → `https://codeberg.org/NielHeesakkers/SyncVault/releases/download/v{V}/SyncVault-{V}.dmg`
   - `version.json` `dmg_url` → Codeberg releases URL.
9. Bump to **3.7.0**, full parity. Build/notarize the app.
10. **Release 3.7.0 the OLD way (through GitHub)** so the installed 3.6.2 sees it: version.json on GitHub `main`, dmg on a GitHub release. ALSO upload the dmg to a Codeberg release + push to Codeberg (so the new URLs already resolve). This is the last GitHub release.
11. Verify: installed 3.6.2 → auto-updates to 3.7.0 (from GitHub) → 3.7.0 then checks Codeberg.

### Phase 4 — Flip git origin to Codeberg
12. `origin` → Codeberg; GitHub becomes a throwaway secondary. Future pushes/tags go to Codeberg (triggers the Forgejo build).

### Phase 5 — First Codeberg-only release (3.7.1), end-to-end proof
13. Do a release entirely on Codeberg: push → Forgejo builds image → Codeberg registry; Codeberg release with dmg; version.json on Codeberg main. Confirm the installed 3.7.0 app updates to 3.7.1 with **no GitHub involved**. This validates the whole chain.

### Phase 6 — Decommission GitHub
14. Remove `.github/workflows/`; update README badges/links to Codeberg; drop the ghcr image.
15. Archive (or delete) the GitHub repo. Update the release-checklist memory to the Codeberg flow.

## Rollback / safety
- Each phase is independently verifiable; GitHub stays intact until Phase 6.
- The bridge release (Phase 3) is the only one-way door for the auto-updater — verify it lands before Phase 6.
- Keep the GitHub repo archived (not deleted) for a grace period in case a stale client needs the old feed.

## Effort note
Multi-session. Phase 1 (runner + workflow) and Phase 3 (bridge release) are the
substantial pieces; Phases 2/4/6 are quick edits + verification.
