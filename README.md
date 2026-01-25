# Outline Docker Compose for Make Nashville

Docker Compose setup for [Outline](https://www.getoutline.com/) wiki, supporting both local development and cloud deployment.

## Services

- **Outline** - Wiki application
- **Caddy** - Reverse proxy with automatic HTTPS
- **PostgreSQL** - Database
- **Redis** - Caching/sessions
- **MinIO** - S3-compatible file storage (local only)

## Local Development

1. Install mkcert and generate local certificates:

   **macOS:**
   ```bash
   brew install mkcert
   ```

   **Linux (Debian/Ubuntu):**
   ```bash
   sudo apt install libnss3-tools
   sudo apt install mkcert
   ```

   **Generate certs:**
   ```bash
   mkcert -install
   mkcert localhost
   ```

2. Copy and configure environment:
   ```bash
   cp .env.example .env
   ```

3. Update `.env` for local:
   ```bash
   DOMAIN=localhost
   URL=https://localhost
   ```

4. Generate secrets:
   ```bash
   openssl rand -hex 32  # Run twice for SECRET_KEY and UTILS_SECRET
   ```

5. Configure Slack authentication in `.env`:
   - Create a Slack app at https://api.slack.com/apps
   - Add redirect URL: `https://localhost/auth/slack.callback`
   - Add User Token Scopes: `identity.avatar`, `identity.basic`, `identity.email`, `identity.team`
   - Copy Client ID and Client Secret to `.env`

6. Start services:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

7. Create MinIO bucket:
   ```bash
   docker compose exec minio mc alias set local http://localhost:9000 minioadmin minioadmin
   docker compose exec minio mc mb local/outline
   ```

8. Access at https://localhost

## Production Deployment

1. Copy and configure environment:
   ```bash
   cp .env.example .env
   ```

2. Update `.env` for production:
   ```
   DOMAIN=wiki.yourdomain.com
   URL=https://wiki.yourdomain.com
   ```

3. Generate secure secrets:
   ```bash
   openssl rand -hex 32  # Run twice for SECRET_KEY and UTILS_SECRET
   ```

4. Configure Google Cloud Storage:
   - Create a bucket in GCS
   - Generate HMAC keys at https://console.cloud.google.com/storage/settings;tab=interoperability
   - Update `.env`:
     ```
     AWS_ACCESS_KEY_ID=your-gcs-hmac-access-key
     AWS_SECRET_ACCESS_KEY=your-gcs-hmac-secret
     AWS_REGION=auto
     AWS_S3_UPLOAD_BUCKET_URL=https://storage.googleapis.com
     AWS_S3_UPLOAD_BUCKET_NAME=your-bucket-name
     AWS_S3_FORCE_PATH_STYLE=true
     ```

5. Configure Slack authentication:
   - Update redirect URL to: `https://wiki.yourdomain.com/auth/slack.callback`

6. Set secure database password in `.env`

7. Start services:
   ```bash
   docker compose up -d
   ```

   Caddy will automatically obtain Let's Encrypt certificates.

## Ports

| Service | Port |
|---------|------|
| HTTPS | 443 |
| HTTP (redirects to HTTPS) | 80 |
| MinIO API (local only) | 9000 |
| MinIO Console (local only) | 9001 |
