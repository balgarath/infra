# Moodle LMS for Make Nashville

## Problem

Make Nashville needs a Learning Management System to deliver training courses (video-based with quizzes) to 700+ members. Course completion must trigger automated tool/equipment access provisioning via the GRIT automation API. Content is created by multiple staff and volunteers.

## Solution

Add Moodle 4.5 LTS to the existing Docker Compose stack on `learn.makenashville.org`, with a lightweight sidecar service that receives Moodle course completion webhooks and provisions tool access via the GRIT API.

## Architecture

```
Internet
  ↓
Caddy (TLS termination)
  ├── wiki.makenashville.org  → Outline
  ├── go.makenashville.org    → Shlink
  ├── links.makenashville.org → oauth2-proxy → Shlink Web
  └── learn.makenashville.org → Moodle (port 8080)
                                    ↓
                              PostgreSQL (moodle DB)

Moodle course completion event
  → local_webhooks plugin
  → grit-provisioner sidecar
  → GRIT API (provision tool access)
```

## Components

### Moodle Service

**Image:** `bitnami/moodle:4.5` (LTS, pinned for stability)

**Docker Compose definition:**

```yaml
moodle:
  image: bitnami/moodle:4.5
  restart: unless-stopped
  environment:
    - MOODLE_DATABASE_TYPE=pgsql
    - MOODLE_DATABASE_HOST=postgres
    - MOODLE_DATABASE_PORT_NUMBER=5432
    - MOODLE_DATABASE_NAME=moodle
    - MOODLE_DATABASE_USER=moodle
    - MOODLE_DATABASE_PASSWORD=${MOODLE_DB_PASSWORD}
    - MOODLE_USERNAME=admin
    - MOODLE_PASSWORD=${MOODLE_ADMIN_PASSWORD}
    - MOODLE_EMAIL=${MOODLE_ADMIN_EMAIL}
    - MOODLE_HOST=learn.makenashville.org
    - MOODLE_SITE_NAME=Make Nashville Learning
    - MOODLE_PORT_NUMBER=8080
    - MOODLE_REVERSEPROXY=true
    - MOODLE_SSLPROXY=true
    - MOODLE_LANG=en
    - PHP_MEMORY_LIMIT=512M
  volumes:
    - moodle_data:/bitnami/moodledata
    - moodle_local:/bitnami/moodle/local
  healthcheck:
    test: ["CMD-SHELL", "curl -sf http://localhost:8080/login/index.php || exit 1"]
    interval: 10s
    timeout: 10s
    retries: 10
    start_period: 120s
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy
```

**Key configuration decisions:**

- **Two volumes only:** `moodledata` for uploads/course content and `moodle/local` for custom plugins. Mounting the full `/bitnami/moodle` directory prevents image upgrades.
- **`MOODLE_REVERSEPROXY=true` + `MOODLE_SSLPROXY=true`:** Required because Caddy terminates TLS.
- **`MOODLE_PORT_NUMBER=8080`:** Explicitly set for forward compatibility (matches the default but protects against image changes).
- **`MOODLE_USERNAME` + `MOODLE_PASSWORD`:** Sets the initial admin credentials on first boot. Without these, the image defaults to `user` / `bitnami`.
- **`PHP_MEMORY_LIMIT=512M`:** Moodle's default 128MB is insufficient for 700+ users with video courses.
- **`start_period: 120s`:** Moodle is slow to initialize, especially on first boot.
- **Pinned to 4.5** (current LTS) rather than `latest` for stability.
- **Redis dependency:** Moodle uses Redis for session and application caching (configured post-deploy via admin UI: Site Administration → Plugins → Caching → Redis store, DB index 3).

### GRIT Provisioner Service

A lightweight Python HTTP server (~100 lines) that bridges Moodle course completions to GRIT tool provisioning.

```yaml
grit-provisioner:
  image: python:3.12-alpine
  restart: unless-stopped
  volumes:
    - ./deploy/grit-provisioner:/app:ro
  command: ["python", "/app/server.py"]
  environment:
    - GRIT_API_URL=${GRIT_API_URL}
    - GRIT_API_KEY=${GRIT_API_KEY}
    - WEBHOOK_SECRET=${MOODLE_WEBHOOK_SECRET}
    - COURSE_TOOL_MAP_PATH=/app/course-tool-map.json
    - SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
  healthcheck:
    test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:8000/health || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 5
```

**Responsibilities:**

1. Validate incoming webhook requests against `WEBHOOK_SECRET` (shared with Moodle's `local_webhooks` plugin config). This is a safety-critical check — without it, anyone on the Docker network could fake a course completion and grant themselves access to dangerous equipment.
2. Receive Moodle `\core\event\course_completed` webhooks (POST with course ID + user info)
3. Look up which GRIT tool/permission maps to that course via `course-tool-map.json`
4. Call the GRIT API to provision access
5. Notify Slack on successful provisioning, and on failure (GRIT API errors, invalid webhooks)
6. On GRIT API failure: log the error and send a Slack alert so staff can manually provision. No automatic retry — failed provisioning is rare and staff should investigate.

**Course-to-tool mapping** (`deploy/grit-provisioner/course-tool-map.json`):

```json
{
  "3": {"grit_tool": "laser_cutter", "name": "Laser Cutter"},
  "5": {"grit_tool": "cnc_router", "name": "CNC Router"}
}
```

Staff update this JSON file when adding new courses — no code changes required.

### Caddy Routing

```caddy
learn.makenashville.org {
  header {
    X-Frame-Options SAMEORIGIN
    X-Content-Type-Options nosniff
    Referrer-Policy strict-origin-when-cross-origin
    -Server
  }
  reverse_proxy moodle:8080
}
```

No oauth2-proxy in front of Moodle. Moodle handles its own authentication via Google OAuth 2 because it needs its own user/role system for course enrollment, grades, and completion tracking.

### Caddy depends_on

The Caddy service must be updated to depend on Moodle being healthy before starting:

```yaml
caddy:
  depends_on:
    ...
    moodle:
      condition: service_healthy
```

### Database

Shares the existing PostgreSQL instance with a separate user and database (same pattern as Shlink).

No init SQL file is needed. The Bitnami Moodle image auto-creates its database on first boot when the `MOODLE_DATABASE_*` env vars are provided. The idempotent block in `update-server.sh` is a safety net for subsequent deploys (e.g., if the DB was dropped or the password changed).

**Idempotent creation in `update-server.sh`:**

```bash
# Create moodle user/db if not exists
docker compose exec -T postgres psql -U outline -tc \
  "SELECT 1 FROM pg_roles WHERE rolname='moodle'" | grep -q 1 || \
  docker compose exec -T postgres psql -U outline -c \
  "CREATE USER moodle WITH PASSWORD '${MOODLE_DB_PASSWORD}';"

docker compose exec -T postgres psql -U outline -c \
  "ALTER USER moodle WITH PASSWORD '${MOODLE_DB_PASSWORD}';"

docker compose exec -T postgres psql -U outline -tc \
  "SELECT 1 FROM pg_database WHERE datname='moodle'" | grep -q 1 || \
  docker compose exec -T postgres psql -U outline -c \
  "CREATE DATABASE moodle OWNER moodle;"
```

### Backups

**Database:** Add `moodle` to the existing daily PostgreSQL backup script alongside Outline and Shlink (same `pg_dump | gzip | gsutil cp` pattern, 14-day retention).

**moodledata volume:** The `moodle_data` volume contains uploaded course content, user files, and plugin data. Database-only backups are insufficient for a full restore. Add a daily `tar` of the moodledata volume to GCS:

```bash
# In the backup script, after database dumps:
sudo docker run --rm -v moodle_data:/data:ro -v /tmp:/backup alpine \
  tar czf /backup/moodledata-$(date +%Y%m%d).tar.gz -C /data .
gsutil cp /tmp/moodledata-$(date +%Y%m%d).tar.gz "gs://${GCS_BUCKET}/backups/"
rm /tmp/moodledata-$(date +%Y%m%d).tar.gz
```

Same 14-day retention as database backups.

## Authentication

Moodle's built-in Google OAuth 2 service handles authentication directly.

**One-time setup via Moodle admin UI:**

1. Create a Google OAuth 2.0 client in GCP console with redirect URI: `https://learn.makenashville.org/admin/oauth2callback.php`
2. In Moodle: Site Administration → Server → OAuth 2 services → Google
3. Enter Client ID and Secret
4. Enable "OAuth 2" authentication plugin under Site Administration → Plugins → Authentication

Members log in with Google accounts. Moodle auto-creates user profiles on first login with name/email from Google, keeping identity consistent with Make Nashville's Google Workspace.

**Note:** `MOODLE_GOOGLE_CLIENT_ID` and `MOODLE_GOOGLE_CLIENT_SECRET` are configured manually through the Moodle admin UI (not via environment variables). The Bitnami image does not support OAuth configuration via env vars. These are a one-time post-deployment setup step, not part of the automated deployment pipeline.

## Email (SMTP)

Moodle sends email for enrollment notifications, password resets, course completion confirmations, and forum digests. SMTP is configured post-deployment via the Moodle admin UI:

**Site Administration → Server → Email → Outgoing mail configuration:**
- SMTP host (e.g., `smtp.gmail.com:587` for Google Workspace)
- SMTP authentication credentials
- TLS/STARTTLS settings

Without SMTP, Moodle will silently fail to send emails. This must be configured before opening the LMS to members.

## Environment Variables & Secrets

New variables added to the deployment pipeline:

| Variable | Purpose |
|----------|---------|
| `MOODLE_DB_PASSWORD` | PostgreSQL password for moodle user (auto-generated) |
| `MOODLE_ADMIN_PASSWORD` | Initial Moodle admin password (auto-generated) |
| `MOODLE_ADMIN_EMAIL` | Admin user email (Make Nashville staff email) |
| `MOODLE_WEBHOOK_SECRET` | Shared secret between local_webhooks and grit-provisioner (auto-generated) |
| `GRIT_API_URL` | GRIT automation API endpoint |
| `GRIT_API_KEY` | GRIT API authentication key |

These flow through the existing pipeline: `.env.production` → GCE instance metadata → `update-server.sh` → `.env` / docker-compose environment.

**Note:** `SLACK_WEBHOOK_URL` is already in the deployment pipeline (used by existing backup alerts). The grit-provisioner reuses it — no new secret needed for Slack notifications.

**Redis DB index allocation:** DB 0 = Outline, DB 1 = reserved (Kutt), DB 2 = Shlink, DB 3 = Moodle.

## Deployment Changes

Files that need modification (following existing patterns):

1. **`.env.production.example`** — add new variables
2. **`deploy/gcloud-setup.sh`** — add secret auto-generation for `MOODLE_DB_PASSWORD` and `MOODLE_ADMIN_PASSWORD`, add all new vars to metadata write block
3. **`deploy/startup.sh`** — add metadata fetch for new vars, add Moodle + grit-provisioner to docker-compose template, update Caddyfile template, update .env template
4. **`deploy/update-server.sh`** — add metadata fetch, moodle DB creation block, update Caddyfile/docker-compose/.env templates, add moodle to backup script
5. **`docker-compose.yml`** — add moodle and grit-provisioner services, add `moodle_data` and `moodle_local` to the volumes block, add moodle to caddy's depends_on
6. **`Caddyfile`** — add `learn.makenashville.org` block
7. **`deploy/grit-provisioner/`** — new directory with `server.py` and `course-tool-map.json`
8. **`.github/workflows/deploy.yml`** — add new secrets to metadata block, SCP grit-provisioner files to server
10. **`deploy/monitoring.sh`** — add uptime check for `learn.makenashville.org`

## Resource Planning

**VM upgrade required:**

- **Current:** e2-medium (2 vCPU, 4GB RAM, 50GB disk)
- **Recommended:** e2-highmem-2 (2 vCPU, 16GB RAM) — more cost-effective than e2-standard-4 since the bottleneck is memory, not CPU. 700+ members with ~30-50 concurrent users at peak doesn't need 4 vCPUs.
- **Disk:** increase from 50GB to 100GB if hosting video locally; 75GB if videos are embedded from YouTube/Vimeo.

Moodle alone needs 2-4GB RAM. With existing services, 16GB provides comfortable headroom before the eventual K8s migration.

## Monitoring

Add `learn.makenashville.org` to the existing uptime check script (`deploy/monitoring.sh`). Same pattern as other services: HTTPS check on `/login/index.php` every 10 seconds from 3 regions, Slack alerting after 10 minutes of downtime.

```bash
CHECK_NAMES=(... uptime-learn)
CHECK_URLS=(... "https://learn.makenashville.org/login/index.php")
```

## Moodle Plugin Requirements

### `local_webhooks`

Fires HTTP webhooks on Moodle events. This is the critical integration point for GRIT provisioning.

**Installation:**

1. Download the plugin from `https://moodle.org/plugins/local_webhooks`
2. Extract into the `moodle_local` volume at `/bitnami/moodle/local/webhooks/`
3. Visit Moodle admin UI — Moodle will detect the new plugin and prompt for installation
4. Alternatively, use Moodle CLI: `php admin/cli/upgrade.php`

**Configuration (via Moodle admin UI):**

1. Site Administration → Server → WebHooks
2. Add a new webhook:
   - **URL:** `http://grit-provisioner:8000/webhook` (internal Docker network)
   - **Secret:** Use the value of `MOODLE_WEBHOOK_SECRET`
   - **Events:** Subscribe to `\core\event\course_completed`
   - **Content type:** JSON

The plugin persists its configuration in the Moodle database, so it survives container restarts.

### OAuth 2 Google

Built into Moodle core. Configured via admin UI (see Authentication section).

## Scale Considerations

- 700+ members, 30+ courses is well within Moodle 4.5's capacity on the recommended VM size
- Moodle's built-in cron (runs every minute by default) handles scheduled tasks like completion checks
- PostgreSQL connection pooling is not required at this scale but could be added later if needed
- Video content should be hosted externally (YouTube/Vimeo embed) or served from moodledata volume — for very large video libraries, consider GCS-backed storage

## Post-Deployment Manual Steps

These are one-time setup tasks performed via the Moodle admin UI after first boot:

1. **Google OAuth 2 configuration** (see Authentication section)
2. **SMTP configuration** (see Email section)
3. **Redis caching:** Site Administration → Plugins → Caching → add Redis store (`redis:6379`, DB index 3)
4. **`local_webhooks` plugin installation and configuration** (see Plugin Requirements section)
5. **Course creation and course-tool-map.json mapping** — create courses, note their IDs, update the JSON mapping file
