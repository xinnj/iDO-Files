# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

iDO-Files is an nginx-based file server with a web UI for listing, downloading, uploading, deleting, and moving/copying files. It runs on OpenResty (nginx + Lua) with Redis for state and Keycloak for OIDC authentication.

## Commands

**Run all unit tests:**
```bash
LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/
```

**Run a single test file:**
```bash
LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/authorize_spec.lua
```
Tests use the [busted](https://olivinelabs.com/busted/) framework with a mock `ngx` global (`lua/tests/mock_ngx.lua`). Test config lives in `.busted`.

Test files: `authorize_spec.lua`, `config_spec.lua`, `files_spec.lua`, `housekeeping_spec.lua`, `housekeeping-admin_spec.lua`, `user_info_spec.lua`.

**Run E2E tests (Playwright):**
```bash
cd tests && bash run.sh              # all browsers
cd tests && bash run.sh chromium     # single browser
cd tests && bash run.sh headed       # headed mode
cd tests && bash run.sh ui           # Playwright UI mode
```
E2E tests require a running OpenResty + Redis instance (the `run.sh` script starts one via `env/start.sh`). Set `TEST_BASE_URL` to point at a different server. Tests live in `tests/tests/`, page objects in `tests/pages/`.

**Build Docker base image (OpenResty + Lua modules):**
```bash
./build-base.sh <tag>
```

**Build the application Docker image:**
```bash
docker build -f Dockerfile -t <tag> --build-arg VERSION=<version> .
```
The build is two-stage: `Dockerfile-base` (OpenResty with Lua modules) and `Dockerfile` (app code on top).

**Deploy:** `./deploy.sh` — rsyncs code to a remote host, builds and pushes the Docker image, then deletes K8s pods to trigger a rolling restart. Configuration comes from `deploy.env`.

## Architecture

### Request flow

Every request is handled inside `nginx.conf`. The config defines named locations for each of the three storage buckets (`download/`, `public/`, `archive/`), plus internal variants (`internal-download/`, `internal-archive/`) that bypass auth. Each location wires up nginx phases:

- `access_by_lua_block` — authentication (OIDC), authorization (RBAC), and concurrent download control
- `content_by_lua_file` — actual request handling (list, serve, upload, delete, move/copy)
- `log_by_lua_block` — concurrent download cleanup after response completes
- `body_filter_by_lua_block` — used by share token flow to set `Content-Length`

The `$store_path` nginx variable maps URL paths to filesystem paths (e.g., a request to `/download/foo/bar.zip` sets `$store_path` to `/data/<URL_PREFIX>/download/foo/bar.zip`). Handlers read this variable to know which file/directory to operate on.

Two additional locations handle housekeeping:
- `/_admin/housekeeping` — triggers the cleanup run (no auth, internal use by CronJob)
- `<URL_PREFIX>fileserver/housekeeping` — serves the admin page and API endpoints (requires auth)

### Key Lua modules (all under `lua/`)

- **`handler.lua`** — Core request handler. For directories: lists files, renders the full HTML page (header, breadcrumbs, toolbar, file list, pagination, modals). For files: serves the file content with inline MIME or attachment disposition. Includes path validation (`validate_fs_path`) and HTML escaping.
- **`authorize.lua`** — RBAC authorization. Reads rules from `/data/config/auth_config.json`, persists them to Redis, and checks whether a user's Keycloak groups are allowed/denied for a given HTTP method + URI path. Rules follow `operation:path_prefix` format (e.g., `all:<URL_PREFIX>download`). Deny rules take priority over allow rules.
- **`oidc.lua`** — Wraps `lua-resty-openidc`. `authenticate(true)` checks the session without redirecting (guest fallback); `authenticate(false)` forces login redirect. Sets `X-USER`, `X-USER-GROUPS`, `X-USER-NAME`, `X-USER-EMAIL` headers.
- **`keycloak.lua`** — Calls Keycloak Admin API (client credentials grant) to resolve user group memberships and usernames. Results are cached in Redis with configurable TTL (`GROUPS_CACHE_TTL`).
- **`user_info.lua`** — Assembles user info (username, isAdmin, writeable) from request headers and RBAC check. Provides HTML conditional rendering via `<!--IF_WRITEABLE-->` / `<!--IF_ADMIN-->` markers.
- **`access-token.lua`** — API tokens (CRUD). Tokens are stored in Redis with per-user sorted sets. Used for Bearer token auth in `authorize.lua`.
- **`share-token.lua`** — Shareable download links with expiration (max 1 year). Stored as user-keyed lists in Redis with a reverse-lookup (`share_token_reverse:*`). The `/share` location validates tokens, resolves the file path, and serves the file.
- **`time-token.lua`** — Time-limited manifest tokens (for `.ipa`/`.hap`/`.app` app install flows). Short-lived Redis keys with auto-expiry.
- **`concurrent-control.lua`** — Limits concurrent downloads per user using `lua-resty-limit-conn` with a shared dict. Controlled via `ENABLE_CONCURRENT_CONTROL`, `MAX_CONCURRENT_DOWNLOADS`, `CONCURRENT_BURST`, `CONCURRENT_DELAY` env vars. Applied only to known download extensions and `/share` paths.
- **`files.lua`** — Filesystem operations: create directories, delete (`rm -rf`), move/copy, path sanitization and validation. All commands use `io.popen` with quoting.
- **`redis_conn.lua`** — Redis connection pool wrapper using keepalive.
- **`config.lua`** — Static data: file extension → Tabler icon mappings, and extension → MIME types for inline browser display.
- **`upload.lua`** / **`upload_file.lua`** — Multipart file upload handling with filename sanitization.
- **`move-copy.lua`** / **`delete.lua`** — Move/copy and delete operations with path sanitization + auth checks.
- **`random.lua`** — Wraps `/dev/urandom` for secure random bytes.
- **`auth-config.lua`** — HTTP endpoint for auth config CRUD. Sub-routes off the same nginx regex location: `GET /fileserver/auth-config` (read) and `POST` (save, two-phase: stage file → sync Redis → rename, with a `version` check returning 409), plus `GET …/roles` (Keycloak realm roles for the picker; always 200, degraded to `source: "unavailable"` when Keycloak is unreachable, `?refresh=1` bypasses the cache) and `GET …/dirs?path=` (bucket subdirectories; entries carry the ready-to-use rule path including `URL_PREFIX`; 400 for traversal or a non-bucket path). Validation enforces the operation vocabulary the matcher actually implements — allow is `read`/`all`, deny is `write`/`all`.

**A role's entry in the config is not guaranteed to have both `allow` and `deny`** — a `deny`-less role is a perfectly normal file, and the deployed ci config has one. Anything in `access-control.js` that indexes `state.rules[role][listName]` must tolerate a missing role *and* a missing list; `renderRulesPanel` guards with `|| { allow: [], deny: [] }` and `validateBeforeSave` with `|| []`, but the write paths (`submitRule`, `removeRule`) originally did neither and threw inside their own click handler — which reads to the user as "the button does nothing", with no dialog error and no toast. Use `ruleListFor()` for writes.

**The server, however, requires both lists on every role.** `validate_config` in `auth-config.lua` rejects an entry that is `{}` or carries only one key, with `Missing allow rules for group <role>`. So a config the editor loads happily can be impossible to save — and since the POST carries the *whole* config, one role missing a list blocks every save from every role, with an error naming a role the user never touched. `normaliseRules()` runs on load and on the save response (before `savedJson` is taken, so the page does not open dirty) and is what keeps the outgoing payload one the server accepts. The seeded fixture has both keys everywhere, so the E2E suite cannot see either half unless a test mocks the config shape explicitly.
- **`dir-listing.lua`** — shared `lfs` directory walker for the admin APIs. Owns the bucket allow-list, `..` rejection, symlink following and the `has_children` probe; the housekeeping rule editor and the access-control path picker both build on it.
- **`admin-share-links.lua`** — Admin endpoint to manage share links across all users.
- **`housekeeping.lua`** — Automated file cleanup with retention rules (keep count, keep days). Scans directories, matches rules by path prefix (most-specific wins, parent rules inherited by children), and deletes files exceeding limits. Triggered via `/_admin/housekeeping` or the CronJob.
- **`housekeeping-admin.lua`** — API backend for the housekeeping admin page. Endpoints: `GET /config` (read config), `POST /config` (write config), `GET /dirs?bucket=&path=` (list subdirectories with rule info), `POST /run` (trigger cleanup dry-run/live with progress).

### Frontend (`fileserver/`)

**The `<URL_PREFIX>` placeholder goes in HTML only.** `Start.sh:49-58` substitutes it in an explicit file list, but the E2E seed script (`tests/fixtures/seed/seed-data.sh`) substitutes it in *every* `.html` and `.js` under `fileserver/`. So a new JS file containing the placeholder passes the entire test suite and then 404s in production. Pages set `window.__URL_PREFIX__` in the HTML (which is already in Start.sh's list) and pass it to extracted scripts, which stay placeholder-free — no Start.sh edit to remember.

**Admin pages** load only `bootstrap.min.css`, `tabler-icons.min.css`, `toast.css`, `admin.css`, `bootstrap.bundle.min.js` and `toast.js`; they are light-only and do **not** load `styles.css` (its global `* { margin: 0; padding: 0 }` reset fights Bootstrap). `js/admin-common.js` holds the shared helpers — escaping, `apiFetch` (which rejects with a `.status` so callers can branch on 409/403) and button busy state.

**`setBusy()` replaces the button's `innerHTML` outright**, so any element inside a button passed to it is destroyed and recreated on every call — a reference cached at page init then points at a detached node and silently stops working. Put state that has to survive a save on the *button* (a class, plus a `::after` for the visual) rather than in a child element. This bit the access-control Save dot: after the first save the dot stayed lit forever, presenting as "Save is disabled but unsaved changes are showing".

The same hazard applies on **any** page that swaps a button's innerHTML while saving, whether or not it uses `setBusy()` — `housekeeping.html`'s `saveConfig()` caches `originalHtml` and restores it in `.finally()`, which is the same destroy-and-recreate. Both pages' unsaved dots are therefore the same `.save-dirty::after` rule, which lives in `admin.css`; the pages only toggle the class (`renderDirtyState()` on access-control, `updateSaveButton()` on housekeeping). `admin-pages.spec.ts` asserts the button has exactly one child element while dirty, which is what catches a dot creeping back into the markup as a span.

**The footer's button conventions.** Secondary actions go left, the primary action rightmost — access-control's `[Refresh] [Export] [Save changes]`, housekeeping's `[Reset] [Save]`, upload's `[Clear All] [Start Upload]`. The dot is the only unsaved-changes signal; housekeeping used to *also* flip its Save between `btn-outline-primary` and `btn-primary`, which said the same thing twice and was dropped. Upload has no dot on purpose: its `Start Upload` is enabled exactly when files are pending, so a dot would mirror the enabled state and carry nothing. Upload's buttons are otherwise metrically identical to the others (same padding, radius, font, 8px icon gap) — `btn-success` is deliberate, because green reads as "go" on the page whose one action is an upload. Note that its `.btn i { margin-right: 8px }` already equals `me-2`, so adding `me-2` there changes nothing.

**`css/admin.css` is the shared shell for `housekeeping.html`, `share-links.html`, `access-token.html`, `upload.html` and `access-control.html`** — body, container, card, card-header, header-section, footer-buttons, btn, table and form controls. Each page's own `<style>` block keeps only what is specific to it.

Two rules for changing it:

- **Link position is load-bearing.** It must come after `bootstrap.min.css` and before the page's own `<style>`. `.btn` and `.container` override Bootstrap classes at the *same specificity* and win only on source order — loaded earlier, `.btn-sm` would beat `.btn` and shrink share-links' row buttons, and `.container` would take Bootstrap's 1320px at ≥1400px.
- **Page width and gutter live in `--page-max` / `--page-gutter`, set per page.** Each admin page declares `:root { --page-max: … }` in its own `<style>` block (900/1200/1200/1400) and `admin.css` points `.container`, its padding, and `.footer-buttons` at them. A 1400px table wants width; `access-token` is 900 and has no footer. The three pages that *do* have a footer — housekeeping, access-control, upload — are all 1200, so their bars are all 1140px. `upload` was 800 on the reasoning that a dropzone does not want width, which quietly made its bar 400px narrower than its siblings for no reason a user could see; the page width is the bar width, so aligning the bar meant widening the page. **The bar cannot be widened on its own** — it is sized against the cards, so widening only the bar puts its corners 200px past them on each side, which is the bug `--page-gutter` was added to fix.

Widening upload's page did not oblige its dropzone to fill it. `.upload-area` carries its own `max-width: 800px` and `margin: 0 auto 20px`, so the dashed target is centred inside a full-width card. **That cap has to sit on `.upload-area`, never on the card** — the card also holds the upload stats and the file list, and those are the things the width is actually for; capping the card caps all three. A page that sets nothing gets the 1200px/12px defaults, which are **not** Bootstrap's 1320px. `--page-gutter` is the container's own side padding — 12px, widened to 30px at ≥1200px — and it exists because **the footer has to line up with the *cards*, not with `.container`'s border box**: the cards sit inside that gutter, so a footer sized to the border box sits proud of them and puts its rounded corners back on the screen edge. The footer used to hardcode `max-width: 1200px` at `left: 0`, which was wrong against the cards on *every* page — 30px proud on the two 1200px pages, 70px inset on `share-links`, and 230px overhanging on `upload`. Never give `.footer-buttons` or `.container` a literal width or side padding — set the variables and let everything follow.

Page-specific things that look like they belong in `admin.css` but do not: `upload.html`'s `.upload-icon i, .base-url-label i, .btn i` icon spacing (its markup uses bare `<i>` where the others use `me-*`, so sharing it double-spaces them), housekeeping's `@media (min-width: 768px)` viewport-height flex block (ID-scoped to its tab panes; shared, it would give share-links an `overflow: hidden` body), and `upload.html`'s `.progress`/`.progress-bar` (moving the transition flips the `prefers-reduced-motion` outcome).

**The viewport-height pages need `max-height: 100%` on their columns.** `housekeeping.html` and `access-control.html` both lock `body` to `100vh; overflow: hidden` above 768px and scroll inside their cards. Because Bootstrap's `.row` sets `flex-wrap: wrap`, a column is stretched to its *flex line* — sized by the tallest card — not to the row, so the card grows to its content height and `body`'s `overflow: hidden` clips the bottom with **no scrollbar anywhere**. `max-height: 100%` on the columns is what prevents it; removing it fails silently in a way only a long list exposes. It pairs with `overflow: hidden` on the row. Each page keeps its own copy: housekeeping's is ID-scoped to `#rulesTab`, access-control's to `#contentSection`, and they are not interchangeable.

Their columns must also use `col-md-*`, not `col-lg-*`. The height-filling layout starts at 768px; `col-lg` would only put the columns side by side at 992px, so between those widths they stack under a locked body and the lower card is unreachable.


- **`template.html`** — Page shell with `<!--HEADER-->`, `<!--TOOLBAR-->`, `<!--FILE_LIST-->`, `<!--PAGINATION-->` etc. placeholders filled server-side by `handler.lua`.
- **`js/app.js`** — Client-side logic: theme toggle (dark/light, persisted in localStorage), search filtering (client-side), sort toggling, context menus, three-dot menus, modals for new-folder/rename/copy-move/delete/share, copy link, download. All modals call PUT/DELETE endpoints on the same bucket with form-encoded or JSON bodies.
- **`js/actions.js`** — Utility functions called from inline `onclick` handlers on file rows.
- **`js/toast.js`** — Toast notification system for success/error feedback.
- **Static pages**: `upload.html`, `viewer.html` (inline file viewer with syntax highlighting via highlight.js + marked.js), `access-token.html`, `access-control.html`, `share-links.html`, `housekeeping.html` (tree-based retention rule editor with dry-run support), `oidc-setup.html`, `app-install.html` (QR code-based app install for `.ipa`/`.hap`/`.app`), `artifacts.html`.
- **Error pages**: `401.html`, `403.html`, `429.html` (rate limiting).
- **CSS**: `styles.css` (custom), `bootstrap.min.css`, `github-dark.min.css` (code highlighting theme), `toast.css`.
- **Icons**: Tabler Icons (`tabler-icons.min.css`, fonts).

### Storage layout

Data lives under `/data/<URL_PREFIX>/` with three buckets: `download/`, `public/`, `archive/`. The `public/` bucket uses optional OIDC auth (`authenticate(true)` — guest fallback); `download/` and `archive/` require explicit authorization. Symlinks `app → download`, `internal-download → download`, `internal-archive → archive` are created at startup.

### Configuration

- **Env vars**: All configuration is via environment variables (see `nginx.conf` `env` directives and `charts/values.yaml`). Key vars: `AUTH_REQUIRED`, `OIDC_*`, `REDIS_*`, `ADMIN_GROUP`, `URL_PREFIX`, `LOGO_TEXT`, `PAGE_LIMIT`, `ENABLE_CONCURRENT_CONTROL`, `MAX_CONCURRENT_DOWNLOADS`, `TOKEN_EXPIRE_MINUTES`, `GROUPS_CACHE_TTL`.
- **`auth_config.json`** — Default RBAC rules. Copied to `/data/config/auth_config.json` on first start if not present.
- **`URL_PREFIX`** — Supports serving under a subpath (e.g., `/myteam/`). The `Start.sh` script sed-replaces `<URL_PREFIX>` placeholders in nginx.conf, template.html, all JS files, and auth_config.json.

### Startup flow (`Start.sh`)

1. Creates required directories under `/data/<URL_PREFIX>/`
2. Copies `fileserver/` static files to `/data/<URL_PREFIX>/fileserver`
3. Copies `auth_config.json` to `/data/config/` (if not exists)
4. Creates `app → download`, `internal-download → download`, `internal-archive → archive` symlinks
5. Sed-replaces `<URL_PREFIX>`, `<NAMESERVER>`, `<NGINX_LOG_LEVEL>` in nginx.conf and static files
6. Starts nginx in foreground

### K8s / Helm

Helm chart in `charts/`. Includes templates for Deployment, Service, Ingress, PVC, HPA, CronJob (housekeeping cleanup), ConfigMaps (oidc setup + housekeeping script), and ServiceAccount. Supports an optional Redis subchart. `createConfigMap` (bool) controls ConfigMap creation for flexibility.

### CI/CD

- **E2E tests** (`.github/workflows/test.yml`): runs on every push to `main` and all PRs. Sets up OpenResty + Redis on macOS, starts the test server, runs Playwright E2E tests (Chromium), and uploads artifacts on failure.
- **Release** (`.github/workflows/release.yml`): on published release, builds the Docker image tagged with the release version + `latest`, pushes to Docker Hub (`docker.io/xinnj/file-server`), packages the Helm chart, and attaches it to the release.
