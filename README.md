# Outline Docker Compose for Make Nashville

Docker Compose setup for [Outline](https://www.getoutline.com/) wiki, supporting local development and GCP deployment.

## Overview

| Service | Local | Production |
|---------|-------|------------|
| **Outline** | `outline:1.4.0` | `outline:1.4.0` |
| **Caddy** | `caddy:2-alpine` (local TLS) | `caddy:2-alpine` (Let's Encrypt) |
| **PostgreSQL** | `postgres:16-alpine` | `postgres:16-alpine` |
| **Redis** | `redis:7-alpine` | `redis:7-alpine` |
| **Storage** | MinIO (local) | Google Cloud Storage |

## Local Development

1. Install mkcert and generate local certificates:

   **macOS:**
   ```bash
   brew install mkcert
   mkcert -install
   mkcert localhost
   ```

   **Linux (Debian/Ubuntu):**
   ```bash
   sudo apt install libnss3-tools mkcert
   mkcert -install
   mkcert localhost
   ```

2. Copy environment file:
   ```bash
   cp .env.example .env
   ```

3. Generate secrets:
   ```bash
   openssl rand -hex 32  # Run twice — paste into SECRET_KEY and UTILS_SECRET in .env
   ```

4. Configure Slack authentication in `.env`:
   - Create a Slack app at https://api.slack.com/apps
   - Add redirect URL: `https://localhost/auth/slack.callback`
   - Add User Token Scopes: `identity.avatar`, `identity.basic`, `identity.email`, `identity.team`
   - Copy Client ID and Client Secret to `.env`

5. Start services:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

6. Create MinIO bucket:
   ```bash
   docker compose exec minio mc alias set local http://localhost:9000 minioadmin minioadmin
   docker compose exec minio mc mb local/outline
   ```

7. Access at https://localhost

## GCP Deployment

All production infrastructure is managed by `deploy/gcloud-setup.sh`. It handles both initial installs and updates.

### First deploy

1. Copy and fill in production credentials:
   ```bash
   cp .env.production.example .env.production
   # Edit .env.production with your values
   ```

2. Run the setup script:
   ```bash
   ./deploy/gcloud-setup.sh
   ```

   This will: reserve a static IP, create the VM, configure GCS CORS, upload the S3Storage.js patch, and start all services via the startup script.

3. Point your DNS A record to the printed static IP, then visit `https://your-domain`.

### Updating an existing instance

Edit `.env.production` as needed, then re-run:
```bash
./deploy/gcloud-setup.sh
```

The script detects the existing instance and applies config changes without recreating the VM.

## Upgrading Outline

The Outline image is pinned to avoid breaking the S3Storage.js patch (see Architecture below).

To upgrade:

1. Check the [Outline changelog](https://github.com/outline/outline/releases) for breaking changes.

2. Update the image tag in all four locations:
   - `docker-compose.yml`
   - `deploy/startup.sh` (in the docker-compose.yml heredoc)
   - `deploy/gcloud-setup.sh` (in the docker-compose.yml heredoc, update path)

3. Extract and patch the new `S3Storage.js` from the new image:
   ```bash
   docker run --rm docker.getoutline.com/outlinewiki/outline:NEW_VERSION \
     cat /opt/outline/build/server/storage/files/S3Storage.js > deploy/S3Storage.js
   ```
   Then re-apply the two patches described below.

4. Test locally before deploying:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

## Architecture

### S3Storage.js patch

Outline's built-in S3 storage doesn't work with Google Cloud Storage out of the box. Two issues affect GCS with uniform bucket-level access:

1. **Missing `Content-Disposition` policy condition** — GCS presigned POST requires a policy condition for every form field. Outline sends `Content-Disposition` but the original code has no matching condition.

2. **ACL field rejected by GCS** — Outline includes `acl: "private"` in presigned POST form fields. GCS rejects any ACL field when uniform bucket-level access is enabled.

`deploy/S3Storage.js` is a patched build artifact that fixes both issues. It is mounted as a read-only volume over the file inside the container:

```yaml
volumes:
  - ./deploy/S3Storage.js:/opt/outline/build/server/storage/files/S3Storage.js:ro
```

Because this patches a compiled build artifact, the patch must be regenerated whenever the Outline image version changes.
