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
- **`auth-config.lua`** — HTTP endpoint for auth config CRUD.
- **`admin-share-links.lua`** — Admin endpoint to manage share links across all users.

### Frontend (`fileserver/`)

- **`template.html`** — Page shell with `<!--HEADER-->`, `<!--TOOLBAR-->`, `<!--FILE_LIST-->`, `<!--PAGINATION-->` etc. placeholders filled server-side by `handler.lua`.
- **`js/app.js`** — Client-side logic: theme toggle (dark/light, persisted in localStorage), search filtering (client-side), sort toggling, context menus, three-dot menus, modals for rename/copy-move/delete/share, copy link, download. All modals call PUT/DELETE endpoints on the same bucket with form-encoded or JSON bodies.
- **`js/actions.js`** — Utility functions called from inline `onclick` handlers on file rows.
- **Static pages**: `upload.html`, `viewer.html` (inline file viewer with syntax highlighting via highlight.js + marked.js), `access-token.html`, `access-control.html`, `share-links.html`, `oidc-setup.html`, `app-install.html`, `artifacts.html`.
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
