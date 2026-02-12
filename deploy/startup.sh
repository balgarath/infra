#!/bin/bash
set -euo pipefail

# GCP Compute Engine Startup Script for Make Nashville Wiki (Outline)
# This script runs on first boot to set up the server

LOG_FILE="/var/log/outline-setup.log"
APP_DIR="/opt/outline"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting Outline wiki setup..."

# Wait for network
sleep 10

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    log "Docker installed successfully"
else
    log "Docker already installed"
fi

# Create application directory
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Fetch configuration from instance metadata
log "Fetching configuration from instance metadata..."
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
    curl -sf -H "$METADATA_HEADER" "$METADATA_URL/$1" || echo ""
}

# Required metadata attributes
DOMAIN=$(get_metadata "domain")
SECRET_KEY=$(get_metadata "secret-key")
UTILS_SECRET=$(get_metadata "utils-secret")
POSTGRES_PASSWORD=$(get_metadata "postgres-password")
GCS_ACCESS_KEY=$(get_metadata "gcs-access-key")
GCS_SECRET_KEY=$(get_metadata "gcs-secret-key")
GCS_BUCKET=$(get_metadata "gcs-bucket")
SLACK_CLIENT_ID=$(get_metadata "slack-client-id")
SLACK_CLIENT_SECRET=$(get_metadata "slack-client-secret")

# Validate required fields
if [[ -z "$DOMAIN" || -z "$SECRET_KEY" || -z "$UTILS_SECRET" ]]; then
    log "ERROR: Missing required metadata attributes (domain, secret-key, utils-secret)"
    exit 1
fi

log "Domain: $DOMAIN"

# Create docker-compose.yml
log "Creating docker-compose.yml..."
cat > docker-compose.yml <<'COMPOSE'
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      - DOMAIN=${DOMAIN}
    depends_on:
      - outline

  outline:
    image: docker.getoutline.com/outlinewiki/outline:latest
    restart: unless-stopped
    env_file: .env
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "outline"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
  caddy_data:
  caddy_config:
COMPOSE

# Create Caddyfile
log "Creating Caddyfile..."
cat > Caddyfile <<CADDY
${DOMAIN} {
	reverse_proxy outline:3000
}
CADDY

# Create .env file
log "Creating .env file..."
cat > .env <<ENV
# Domain Configuration
DOMAIN=${DOMAIN}
URL=https://${DOMAIN}

# Outline
NODE_ENV=production
SECRET_KEY=${SECRET_KEY}
UTILS_SECRET=${UTILS_SECRET}
PORT=3000
HOST=0.0.0.0

# Database
DATABASE_URL=postgres://outline:${POSTGRES_PASSWORD:-outline}@postgres:5432/outline
PGSSLMODE=disable
POSTGRES_USER=outline
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-outline}
POSTGRES_DB=outline

# Redis
REDIS_URL=redis://redis:6379

# Storage (Google Cloud Storage)
FILE_STORAGE=s3
AWS_S3_UPLOAD_BUCKET_NAME=${GCS_BUCKET:-outline}
AWS_S3_ACL=private
AWS_ACCESS_KEY_ID=${GCS_ACCESS_KEY:-}
AWS_SECRET_ACCESS_KEY=${GCS_SECRET_KEY:-}
AWS_REGION=auto
AWS_S3_UPLOAD_BUCKET_URL=https://storage.googleapis.com
AWS_S3_FORCE_PATH_STYLE=true

# Authentication (Slack)
SLACK_CLIENT_ID=${SLACK_CLIENT_ID:-}
SLACK_CLIENT_SECRET=${SLACK_CLIENT_SECRET:-}
ENV

# Set proper permissions
chmod 600 .env

# Pull images
log "Pulling Docker images..."
docker compose pull

# Start services
log "Starting services..."
docker compose up -d

# Wait for services to be healthy
log "Waiting for services to start..."
sleep 30

# Check status
docker compose ps

log "Setup complete! Outline should be available at https://${DOMAIN}"
log "Note: DNS must point to this server's external IP for HTTPS to work"
