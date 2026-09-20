# iDO-Files

A self-hosted file server with a web UI — browse, download, upload, delete, and share files. Built on OpenResty (nginx + Lua) with Redis-backed state and OIDC authentication.

> **TODO: Add screenshots**
> - Main file listing (light mode)
> - Dark mode
> - Context/action menu on a file
> - Share link or admin page

## Features

- **Browse & manage files** — list directories, download files, upload via drag-and-drop, create folders, rename, delete, move/copy
- **Three storage buckets** — `download/`, `public/`, `archive/` with independent access control
- **OIDC authentication** — sign in with Keycloak (or any OpenID Connect provider), with optional guest access on public paths
- **RBAC authorization** — JSON rules file maps Keycloak realm roles to allowed/denied HTTP methods and path prefixes
- **Share links** — generate time-limited shareable download links (configurable expiry, max 1 year)
- **API tokens** — per-user bearer tokens for programmatic access
- **App install manifests** — time-limited tokens for `.ipa`/`.hap`/`.app` install flows
- **Concurrent download limits** — per-user rate limiting with configurable burst and delay
- **Dark mode** — theme toggle persisted in localStorage
- **Code viewer** — inline syntax highlighting for source files
- **Search & sort** — client-side filtering and column sorting in the file listing
- **Housekeeping** — automated file cleanup with configurable retention rules (keep count, keep days), dry-run mode, and a tree-based admin UI
- **Internal endpoints** — `/internal-download/` and `/internal-archive/` bypass authentication for service-to-service access; `/internal-download/` also accepts unauthenticated `POST` uploads into the download bucket
- **Mobile-friendly** — responsive UI built with Bootstrap

## Quick Start

### Docker

```bash
docker run -d \
  --name ido-files \
  -p 8080:80 \
  -v /path/to/data:/data \
  -e REDIS_HOST=redis \
  -e REDIS_PASSWORD=fileserver \
  -e AUTH_REQUIRED=false \
  -e LOGO_TEXT="My Files" \
  -e URL_PREFIX=/ \
  docker.io/xinnj/file-server:latest
```

Open http://localhost:8080/ in your browser.

### Kubernetes (Helm)

```bash
# Clone and install with defaults (includes Redis)
helm install file-server ./charts \
  --set env[0].value=/myteam
```

Or create a `values.yaml` override:

```yaml
env:
  - name: URL_PREFIX
    value: /myteam
  - name: AUTH_REQUIRED
    value: "true"
  - name: OIDC_DISCOVERY_URL
    value: https://keycloak.example.com/realms/myrealm
  - name: OIDC_CLIENT_ID
    value: fileserver
  - name: OIDC_CLIENT_SECRET
    value: <secret>

ingress:
  enabled: true
  hosts:
    - host: files.example.com
      paths:
        - path: /myteam
          pathType: ImplementationSpecific

persistence:
  enabled: true
  size: 50Gi
```

Then install:

```bash
helm install file-server ./charts -f values.yaml
```

## Configuration

All configuration is via environment variables.

| Variable | Default | Description |
|---|---|---|
| `URL_PREFIX` | `/` | Sub-path prefix when serving behind a reverse proxy (e.g. `/myteam`) |
| `LOGO_TEXT` | `My Files` | Text displayed in the navbar |
| `PAGE_LIMIT` | `25` | Files per page in directory listings |
| `AUTH_REQUIRED` | `false` | Require authentication (`true`/`false`) |
| **OIDC** | | |
| `OIDC_DISCOVERY_URL` | — | OpenID Connect discovery URL (e.g. `https://keycloak.example.com/realms/myrealm`) |
| `OIDC_CLIENT_ID` | — | OIDC client ID |
| `OIDC_CLIENT_SECRET` | — | OIDC client secret |
| `OIDC_REDIRECT_URI` | — | OIDC redirect URI (defaults to `$scheme://$host:<URL_PREFIX>/redirect_uri`) |
| `OIDC_LOGOUT_PATH` | — | Logout path (defaults to `<URL_PREFIX>/logout`) |
| `OIDC_LOGOUT_REDIRECT_URI` | — | Post-logout redirect |
| `OIDC_SSL_VERIFY` | `yes` | Verify OIDC provider SSL certificate |
| **Redis** | | |
| `REDIS_HOST` | `redis` | Redis host |
| `REDIS_PORT` | `6379` | Redis port |
| `REDIS_PASSWORD` | — | Redis password |
| **RBAC** | | |
| `ADMIN_GROUP` | `fileserver_admin` | Keycloak realm role granted full admin access |
| `GROUPS_CACHE_TTL` | `300` | Realm role membership and realm role list cache TTL in seconds |
| **Tokens** | | |
| `TOKEN_EXPIRE_MINUTES` | `6` | API token default expiry in minutes |
| **Concurrent control** | | |
| `ENABLE_CONCURRENT_CONTROL` | `true` | Enable per-user download concurrency limiting |
| `MAX_CONCURRENT_DOWNLOADS` | `5` | Max concurrent downloads per user |
| `CONCURRENT_BURST` | `2` | Burst allowance above the limit |
| `CONCURRENT_DELAY` | `1` | Delay in seconds when limit is exceeded |

## Storage Buckets

Data lives under `/data/<URL_PREFIX>/` with three buckets:

| Bucket | Path | Auth | Purpose |
|---|---|---|---|
| `download` | `/data/<URL_PREFIX>/download` | Required (when `AUTH_REQUIRED=true`) | Private files — core storage |
| `public` | `/data/<URL_PREFIX>/public` | Optional (guest fallback) | Publicly accessible files |
| `archive` | `/data/<URL_PREFIX>/archive` | Required (when `AUTH_REQUIRED=true`) | Archived/read-only storage |

A symlink `app → download` is created at startup, so `/app/` serves the same content as `/download/`.

Two internal endpoints (`/internal-download/`, `/internal-archive/`) bypass authentication for service-to-service access. `/internal-download/` additionally accepts unauthenticated `POST` uploads (multipart) that write into the `download` bucket.

## Authentication & Authorization

### OIDC

When `AUTH_REQUIRED` is `true`, users are redirected to the configured OIDC provider for login. After authentication, the user's realm roles are read from the access token, and can also be resolved from Keycloak via its Admin API and cached in Redis.

The `public/` bucket uses a softer check — it attempts to resolve the session but falls back to guest access if no valid session exists.

#### Required Keycloak client permissions

The OIDC client must have **service accounts enabled**, and its service account needs these roles from the realm's built-in `realm-management` client:

| Role | Needed for |
|---|---|
| `view-users` | Resolving a signed-in user's realm roles — without it, authorization cannot determine what a user may reach |
| `view-realm` | Listing realm roles for the access-control role picker (`GET /fileserver/auth-config/roles`). Without it that endpoint returns 403 and the picker falls back to the roles already in the config, with a notice explaining why |

In the Keycloak admin console: **Clients → your client → Service accounts roles → Assign role → Filter by clients → realm-management**. Granting only `view-users` is the usual starting point and is enough for authorization; add `view-realm` to get the full role list in the UI.

### RBAC Rules

Authorization rules are stored in `/data/config/auth_config.json` and persisted to Redis. Rules map Keycloak **realm roles** to allowed/denied operations. (Throughout the codebase these are called "groups" — `X-USER-GROUPS`, `ADMIN_GROUP`, the keys below — but they are realm roles: the header is built from the access token's `realm_access.roles`, and the admin API call behind it reads `/users/{id}/role-mappings/realm`.)

```json
{
  "version": 1,
  "rules": {
    ".default": {
      "allow": [],
      "deny": []
    },
    "fileserver_admin": {
      "allow": [
        "all:<URL_PREFIX>download",
        "all:<URL_PREFIX>archive",
        "all:<URL_PREFIX>public"
      ],
      "deny": []
    }
  }
}
```

- Rules follow the format `operation:path_prefix` (e.g. `read:<URL_PREFIX>download/file.txt`, `all:<URL_PREFIX>download`)
- Paths are matched against the request URL by plain prefix, and must therefore begin with `<URL_PREFIX>`. A path matches everything beneath it, so `all:/download` also covers `/download/team-a/releases`.
- **Allow accepts only `read` (GET/HEAD/OPTIONS) and `all`. Deny accepts only `write` (POST/PUT/PATCH/DELETE) and `all`.** `allow:write` and `deny:read` are not implemented by the matcher, so the save endpoint rejects them rather than storing a rule that silently never matches.
- Deny rules take priority over allow rules, across all of a user's roles
- The special role `.default` is the fallback for users with no explicit roles, and is also consulted when no other role's rules match
- Rule order does not matter — rules are stored in Redis sets
- Rules can be managed from the admin UI (`/access-control`)

#### Admin API

Both endpoints require the `ADMIN_GROUP` role.

- `GET /fileserver/auth-config` — the stored config, verbatim
- `POST /fileserver/auth-config` — replaces it. The body is `{version, rules}`; a version mismatch returns `409`, and an out-of-vocabulary operation returns `400` naming the offending role, list and position. The save applies to Redis before the file is replaced, so a failure at either step leaves both untouched.
- `GET /fileserver/auth-config/roles` — realm roles for the role picker. Always `200`: when Keycloak is unreachable the response is `{"roles": [], "source": "unavailable", "degraded": true, "error": ...}` and the page falls back to the roles already in the config. Pass `?refresh=1` to bypass the Redis cache.
- `GET /fileserver/auth-config/dirs?path=<url path>` — immediate subdirectories of a bucket folder, for the path picker. Each entry carries the ready-to-use rule path including `<URL_PREFIX>`. Returns `400` for a missing path, a traversal attempt, or a path outside `download`/`public`/`archive`.

### API Tokens

Users can create personal API tokens from the UI (`/access-token`). Tokens are stored per-user in Redis and accepted as Bearer tokens. Admins can manage all tokens.

### Share Links

Time-sensitive share links are created from the file context menu. Each link is a unique token stored in Redis with configurable expiry (up to 1 year). Access is at `/share/<token>`.

## Development

### Prerequisites

- OpenResty (or nginx with `lua-nginx-module`, `ngx_devel_kit`)
- Lua 5.1 with luarocks
- Redis
- [busted](https://olivinelabs.com/busted/) (for tests)

### Running tests

```bash
LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/
```

Tests use a mock `ngx` global defined in `lua/tests/mock_ngx.lua`.

### Building the Docker image

```bash
./build.sh <tag>
```

This builds the base OpenResty image (`Dockerfile-base`) first, then the application image (`Dockerfile`).

## Architecture

```mermaid
flowchart TD
    Browser[Browser] -->|HTTPS| Nginx

    subgraph Nginx[OpenResty]
        OIDC[OIDC<br/>auth & session]
        RBAC[RBAC<br/>realm-role allow/deny]
        Handlers[File Handlers<br/>list, download, upload<br/>delete, move/copy, share]
        OIDC --> RBAC --> Handlers
    end

    Handlers --> Redis[Redis<br/>sessions, tokens, auth rules, role cache]
    Handlers --> Disk[Disk<br/>/data/download, /data/public, /data/archive]

    Handlers --> Keycloak[Keycloak<br/>realm roles, user info]
    OIDC --> Keycloak
```

Key Lua modules live under `lua/` — `handler.lua` (core request handling), `authorize.lua` (RBAC), `oidc.lua` (authentication), `keycloak.lua` (realm-role resolution), plus modules for tokens, uploads, file operations, and concurrency control.

## CI/CD

- **Tests** — E2E tests (Playwright) run on every push to `main` and all PRs, spinning up OpenResty + Redis to verify the full stack.
- **Release** — On published releases: builds the Docker image (version tag + `latest`), pushes to Docker Hub, packages the Helm chart, and attaches it to the release.

## License

[Apache License 2.0](LICENSE)
