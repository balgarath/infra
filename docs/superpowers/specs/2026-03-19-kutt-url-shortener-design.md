# Kutt URL Shortener — Design Spec

## Overview

Add a Kutt instance to the existing Docker Compose stack to provide URL shortening and redirect management for Make Nashville at `to.makenashville.org`. The admin interface is gated by Google Workspace OIDC via oauth2-proxy, restricted to members of a specific Google Group. Short link redirects are public — anyone with a link can follow it.

## Goals

- Short, branded URLs (e.g., `to.makenashville.org/donate`)
- Custom slugs and auto-generated slugs
- Link analytics (click tracking, referrer stats)
- Google Workspace authentication with group-based access control for link management
- Public redirects — no auth required to follow a short link
- Share existing Postgres and Redis infrastructure

## Architecture

```
Internet → Caddy (TLS, ports 80/443)
              ├── wiki.makenashville.org → Outline:3000
              └── to.makenashville.org
                    ├── /oauth2/*       → oauth2-proxy:4180
                    ├── /api/*          → forward_auth(oauth2-proxy) → Kutt:3001
                    ├── / (admin UI)    → forward_auth(oauth2-proxy) → Kutt:3001
                    └── /:slug (redirects) → Kutt:3001 (public, no auth)
```

### New Containers

- **kutt** (`kutt/kutt:v3.2.3`) — URL shortener, port 3001
- **oauth2-proxy** (`quay.io/oauth2-proxy/oauth2-proxy:v7.7.1`) — Google OIDC auth gate, port 4180

### Shared Infrastructure

- **Postgres** — new `kutt` database and `kutt` user on existing instance
- **Redis** — shared instance, Kutt uses DB index 1 (Outline uses default DB 0)

## Auth Flow

### Public Redirects (No Auth)

Any request to `to.makenashville.org/<slug>` is proxied directly to Kutt with no auth check. This is the path end users follow when clicking a short link.

### Admin Access (Google Workspace Auth)

1. User visits `to.makenashville.org/` (admin UI) or `to.makenashville.org/api/*`
2. Caddy's `forward_auth` sends subrequest to oauth2-proxy
3. oauth2-proxy sees no valid session cookie → redirects to Google OIDC login
4. User authenticates with Make Nashville Google Workspace account
5. oauth2-proxy checks Google Group membership (e.g., `kutt-users@makenashville.org`)
6. If authorized → session cookie set, request proxied to Kutt
7. Subsequent requests pass through automatically (cookie is valid)

### Auth Requirements

- Google OAuth app in Cloud Console with redirect URI `https://to.makenashville.org/oauth2/callback`
- Google Group for access control (to be created)
- Service account with domain-wide delegation for group membership checks
- Kutt's own registration disabled (`DISALLOW_REGISTRATION=true`), email auth disabled (`MAIL_ENABLED=false`)

## oauth2-proxy Configuration

Key environment variables:

| Variable | Value |
|---|---|
| `OAUTH2_PROXY_PROVIDER` | `google` |
| `OAUTH2_PROXY_CLIENT_ID` | (from Google Cloud Console) |
| `OAUTH2_PROXY_CLIENT_SECRET` | (from Google Cloud Console) |
| `OAUTH2_PROXY_COOKIE_SECRET` | (generated, 32-byte base64) |
| `OAUTH2_PROXY_COOKIE_SECURE` | `true` |
| `OAUTH2_PROXY_EMAIL_DOMAINS` | `makenashville.org` |
| `OAUTH2_PROXY_GOOGLE_GROUP` | (group email, e.g., `kutt-users@makenashville.org`) |
| `OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL` | (workspace admin email for API calls) |
| `OAUTH2_PROXY_GOOGLE_SERVICE_ACCOUNT_JSON` | (path to service account key file) |
| `OAUTH2_PROXY_REDIRECT_URL` | `https://to.makenashville.org/oauth2/callback` |
| `OAUTH2_PROXY_UPSTREAM` | `static://202` |
| `OAUTH2_PROXY_HTTP_ADDRESS` | `0.0.0.0:4180` |
| `OAUTH2_PROXY_REVERSE_PROXY` | `true` |

## Caddy Configuration

New site block for `to.makenashville.org`. The key design: only protect admin routes, leave slug redirects public.

```caddyfile
to.makenashville.org {
    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    # OAuth callback/sign-in routes
    handle /oauth2/* {
        reverse_proxy oauth2-proxy:4180
    }

    # Protected routes: admin UI (exact root) and API
    # Uses route directive to enforce ordering within the block
    @protected {
        path / /api /api/*
    }
    handle @protected {
        forward_auth oauth2-proxy:4180 {
            uri /oauth2/auth
            header_up X-Forwarded-Host {host}
            copy_headers X-Auth-Request-User X-Auth-Request-Email
        }
        reverse_proxy kutt:3001
    }

    # Everything else (slug redirects) — public, no auth
    handle {
        reverse_proxy kutt:3001
    }
}
```

Note: The `@protected` named matcher uses exact path matching for `/` and `/api`, and prefix matching for `/api/*`. This ensures slug paths like `/donate` fall through to the public `handle` block.

### Complete Caddyfile

The final Caddyfile with both site blocks (preserving `{$DOMAIN}` for Outline):

```caddyfile
{$DOMAIN} {
    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }
    reverse_proxy outline:3000
}

to.makenashville.org {
    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    handle /oauth2/* {
        reverse_proxy oauth2-proxy:4180
    }

    @protected {
        path / /api /api/*
    }
    handle @protected {
        forward_auth oauth2-proxy:4180 {
            uri /oauth2/auth
            header_up X-Forwarded-Host {host}
            copy_headers X-Auth-Request-User X-Auth-Request-Email
        }
        reverse_proxy kutt:3001
    }

    handle {
        reverse_proxy kutt:3001
    }
}
```

### Deploy Script Impact

Both `deploy/gcloud-setup.sh` and `deploy/startup.sh` currently regenerate the Caddyfile from inline heredoc templates containing only the Outline site block. These must be updated to either:
- **(Recommended)** SCP the repo's static `Caddyfile` instead of regenerating it inline
- Or update both heredoc templates to include the full multi-site Caddyfile above

If the inline templates are not updated, every deploy will overwrite the Caddyfile and remove the Kutt site block.

## Database & Storage

### Postgres

- New database `kutt` with dedicated user `kutt` and its own password
- Init script `deploy/init-kutt-db.sql` mounted at `/docker-entrypoint-initdb.d/` handles fresh deployments
- **Existing deployment migration:** The deploy script (`gcloud-setup.sh`) must create the database and user if they don't exist, using:
  ```sql
  SELECT 'CREATE USER kutt WITH PASSWORD '\''<password>'\''' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kutt')\gexec
  SELECT 'CREATE DATABASE kutt OWNER kutt' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kutt')\gexec
  ```
  Run via `docker compose exec postgres psql -U outline` during deploy.

### Redis

- Shared Redis instance
- Kutt configured with `REDIS_HOST=redis`, `REDIS_PORT=6379`, `REDIS_DB=1` to isolate from Outline (which uses the default DB 0)

### No File Storage

Kutt stores only link records in Postgres. No GCS/S3 integration needed.

## Kutt Configuration

Key environment variables (stored in `kutt.env`):

| Variable | Value |
|---|---|
| `DEFAULT_DOMAIN` | `to.makenashville.org` |
| `PORT` | `3001` |
| `DB_CLIENT` | `pg` |
| `DB_HOST` | `postgres` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `kutt` |
| `DB_USER` | `kutt` |
| `DB_PASSWORD` | (generated) |
| `REDIS_ENABLED` | `true` |
| `REDIS_HOST` | `redis` |
| `REDIS_PORT` | `6379` |
| `REDIS_DB` | `1` |
| `JWT_SECRET` | (generated) |
| `DISALLOW_REGISTRATION` | `true` |
| `DISALLOW_ANONYMOUS_LINKS` | `true` |
| `MAIL_ENABLED` | `false` |
| `SITE_NAME` | `Make Nashville Links` |
| `TRUST_PROXY` | `true` |
| `ADMIN_EMAILS` | `admin@makenashville.org` |
| `DISALLOW_LOGIN_FORM` | `true` |

The Kutt container uses `env_file: kutt.env`. Production values are injected by the deploy script from `.env.production`.

### User Bootstrapping

Since registration and email are disabled, the first admin user is created via a one-time SQL insert after Kutt's initial migration creates its tables:

```sql
INSERT INTO users (email, password, verified, role)
VALUES ('admin@makenashville.org', '<bcrypt-hash>', true, 'ADMIN');
```

The deploy script should run this after the first `docker compose up` if the users table is empty. The bcrypt hash can be generated with: `htpasswd -nbBC 12 "" '<password>' | cut -d: -f2`

Additionally, set `ADMIN_EMAILS=admin@makenashville.org` in `kutt.env` — Kutt's migration checks this env var to auto-promote matching users to ADMIN role.

## Container Dependencies

```
kutt → postgres (healthy), redis (healthy)
oauth2-proxy → (none — standalone auth proxy)
caddy → outline (healthy), oauth2-proxy (healthy), kutt (healthy)
```

oauth2-proxy has no service dependencies — it only needs to reach Google's OIDC endpoints.

### Healthchecks

All new containers need healthchecks since Caddy depends on them via `condition: service_healthy`:

- **kutt:** `wget -qO /dev/null http://localhost:3001/api/v2/health || exit 1`
- **oauth2-proxy:** `wget -qO /dev/null http://localhost:4180/ping || exit 1`

## Backup

Update the existing `backup.sh` to also dump the `kutt` database:

```bash
docker compose exec -T postgres pg_dump -U kutt kutt | gzip > kutt_backup.sql.gz
gcloud storage cp kutt_backup.sql.gz gs://make-nashville-wiki-uploads/backups/kutt_$(date +%Y%m%d).sql.gz
```

## Files Changed

### Modified

- `docker-compose.yml` — add kutt, oauth2-proxy containers; add Postgres init script volume; update Caddy depends_on
- `Caddyfile` — add `to.makenashville.org` site block
- `.env` — add Kutt and oauth2-proxy variables for local dev
- `.env.production` — add production credentials (Google OAuth, Kutt secrets, Kutt DB password, JWT secret)
- `deploy/gcloud-setup.sh` — SCP new files (`kutt.env`, `init-kutt-db.sql`, service account key); create Kutt database on existing Postgres if needed; update Caddyfile deployment
- `deploy/backup.sh` — add `kutt` database dump

### New

- `deploy/init-kutt-db.sql` — creates `kutt` database and user (fresh deployments only)
- `kutt.env` — Kutt-specific environment file (all Kutt env vars from the table above)

## Manual Prerequisites (Before Deploy)

1. Create DNS A record: `to.makenashville.org` → `35.239.115.94`
2. Create Google OAuth app in Cloud Console with redirect URI `https://to.makenashville.org/oauth2/callback`
3. Create Google Group for access control (e.g., `kutt-users@makenashville.org`)
4. Create service account with domain-wide delegation for group membership checks; download JSON key
5. Add Google OAuth credentials, service account key path, and Kutt secrets to `.env.production`
