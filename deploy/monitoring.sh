#!/bin/bash
set -euo pipefail

# GCP Uptime Check Setup for Make Nashville Services
# Idempotent — safe to re-run. Creates resources if missing, skips if they exist.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env.production"

# ============================================
# Check dependencies
# ============================================
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed"; exit 1; }

# ============================================
# Load configuration
# ============================================
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env.production not found"
    echo "Copy .env.production.example to .env.production and fill in your values"
    exit 1
fi

echo "Loading configuration from .env.production..."
set -a
source "$ENV_FILE"
set +a

# ============================================
# Validate required fields
# ============================================
if [[ -z "${PROJECT_ID:-}" ]]; then
    echo "ERROR: PROJECT_ID is required in .env.production"
    exit 1
fi

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "ERROR: SLACK_WEBHOOK_URL is required for uptime monitoring"
    echo "Alerting without a webhook is pointless — set SLACK_WEBHOOK_URL in .env.production"
    exit 1
fi

gcloud config set project "$PROJECT_ID"

# ============================================
# Enable Cloud Monitoring API
# ============================================
echo "Enabling Cloud Monitoring API..."
gcloud services enable monitoring.googleapis.com

# ============================================
# Define checks (ordered arrays for deterministic iteration)
# ============================================
CHECK_NAMES=(uptime-wiki uptime-grithub uptime-members uptime-website)
CHECK_URLS=("https://wiki.makenashville.org" "https://makenashville.grithub.app/" "https://members.makenashville.org/" "https://makenashville.org")

if [[ -n "${HOME_ASSISTANT_URL:-}" ]]; then
    CHECK_NAMES+=(uptime-homeassistant)
    CHECK_URLS+=("$HOME_ASSISTANT_URL")
else
    echo "HOME_ASSISTANT_URL not set — skipping Home Assistant uptime check"
fi

AUTH_HEADER="Authorization: Bearer $(gcloud auth print-access-token)"
MONITORING_API="https://monitoring.googleapis.com/v3/projects/$PROJECT_ID"

echo ""
echo "============================================"
echo "Make Nashville Uptime Check Setup"
echo "============================================"
echo "Project: $PROJECT_ID"
echo "Checks: ${CHECK_NAMES[*]}"
echo ""

# ============================================
# Create Slack notification channel (if not exists)
# ============================================
echo "Checking for existing Slack notification channel..."

CHANNELS_RESPONSE=$(curl -s \
    -H "$AUTH_HEADER" \
    "$MONITORING_API/notificationChannels" \
    || { echo "ERROR: Failed to list notification channels"; exit 1; })

EXISTING_CHANNEL=$(echo "$CHANNELS_RESPONSE" \
    | jq -r '.notificationChannels[]? | select(.type == "webhook_tokenauth" and .labels.url == "'"$SLACK_WEBHOOK_URL"'") | .name' \
    | head -n1)

if [[ -n "$EXISTING_CHANNEL" ]]; then
    echo "Slack notification channel already exists: $EXISTING_CHANNEL"
    CHANNEL_NAME="$EXISTING_CHANNEL"
else
    echo "Creating Slack notification channel..."
    CHANNEL_RESPONSE=$(curl -s \
        -X POST \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        "$MONITORING_API/notificationChannels" \
        -d '{
            "type": "webhook_tokenauth",
            "displayName": "Make Nashville Slack",
            "labels": {
                "url": "'"$SLACK_WEBHOOK_URL"'"
            }
        }' || { echo "ERROR: Failed to create notification channel"; exit 1; })
    CHANNEL_NAME=$(echo "$CHANNEL_RESPONSE" | jq -r '.name')
    if [[ -z "$CHANNEL_NAME" || "$CHANNEL_NAME" == "null" ]]; then
        echo "ERROR: Failed to create notification channel"
        echo "$CHANNEL_RESPONSE" | jq .
        exit 1
    fi
    echo "Created notification channel: $CHANNEL_NAME"
fi

# ============================================
# Create uptime checks
# ============================================
EXISTING_CHECKS=$(gcloud monitoring uptime list-configs --format="value(displayName)" 2>/dev/null || echo "")

for i in "${!CHECK_NAMES[@]}"; do
    CHECK_NAME="${CHECK_NAMES[$i]}"
    CHECK_URL="${CHECK_URLS[$i]}"

    if echo "$EXISTING_CHECKS" | grep -q "^${CHECK_NAME}$"; then
        echo "Uptime check '$CHECK_NAME' already exists — skipping"
        continue
    fi

    # Parse host and path from URL
    CHECK_HOST=$(echo "$CHECK_URL" | sed -E 's|https?://([^/]+).*|\1|')
    CHECK_PATH=$(echo "$CHECK_URL" | sed -E 's|https?://[^/]+||')
    CHECK_PATH="${CHECK_PATH:-/}"

    echo "Creating uptime check '$CHECK_NAME' for $CHECK_URL..."
    gcloud monitoring uptime create "$CHECK_NAME" \
        --resource-type=uptime-url \
        --resource-labels=host="$CHECK_HOST",project_id="$PROJECT_ID" \
        --path="$CHECK_PATH" \
        --protocol=https \
        --period=10 \
        --timeout=10 \
        --regions=usa-iowa,usa-oregon,usa-virginia \
        --validate-ssl=true

    echo "Created uptime check: $CHECK_NAME"
done
