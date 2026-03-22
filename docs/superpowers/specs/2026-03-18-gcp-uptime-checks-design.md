# GCP Uptime Checks Design

## Goal

Monitor Make Nashville service availability via GCP Cloud Monitoring uptime checks with Slack alerting on downtime.

## Services to Monitor

| Name | URL | Required |
|------|-----|----------|
| Wiki | `https://wiki.makenashville.org` | Yes |
| Grithub | `https://makenashville.grithub.app/` | Yes |
| Members | `https://members.makenashville.org/` | Yes |
| Website | `https://makenashville.org` | Yes |
| Home Assistant | `${HOME_ASSISTANT_URL}` | No — skipped if unset |

## Check Configuration

- **Protocol**: HTTPS GET
- **Expected response**: 2xx status code
- **SSL validation**: Enabled (early warning for cert renewal failures)
- **Timeout**: 10 seconds
- **Interval**: 10 minutes
- **Regions**: `usa-iowa`, `usa-oregon`, `usa-virginia` (3-region minimum required by GCP API)
- **Failure threshold**: 2 consecutive failures before alerting (~20 minutes to alert)

## Architecture

### New file: `deploy/monitoring.sh`

Idempotent shell script using `gcloud` CLI and Cloud Monitoring REST API. Can be re-run safely — creates resources if missing, skips if they already exist.

**Prerequisites:**

- Enable `monitoring.googleapis.com` API (script handles this)
- `SLACK_WEBHOOK_URL` must be set (script exits with error if missing, since alerting is the whole point)

**Steps:**

1. Source `.env.production` for `SLACK_WEBHOOK_URL` and `HOME_ASSISTANT_URL`
2. Enable Cloud Monitoring API (`gcloud services enable monitoring.googleapis.com`)
3. Find an existing native Slack notification channel (set up manually in GCP Console). The script errors with setup instructions if none is found.
4. Create uptime checks (if not exists, checked via `gcloud monitoring uptime list-configs`):
   - `uptime-wiki`
   - `uptime-grithub`
   - `uptime-members`
   - `uptime-website`
   - `uptime-homeassistant` (skipped if `HOME_ASSISTANT_URL` is empty)
5. Create one alert policy per uptime check via REST API, each with:
   - Metric filter: `metric.type="monitoring.googleapis.com/uptime_check/check_passed"` filtered to the specific check
   - Condition: uptime check fails for 2 consecutive 10-minute periods
   - Notification: Slack channel created in step 3
   - Check existence by display name before creating

### Naming convention

All resources prefixed with `uptime-` for easy identification and cleanup.

### Alert policies

- One policy per check, so Slack messages clearly identify which service is down
- Display names: `uptime-alert-wiki`, `uptime-alert-grithub`, etc.
- Notification: Slack webhook (same one used for deploy/backup notifications)

## Configuration

### `.env.production` additions

```
HOME_ASSISTANT_URL=https://your-home-assistant-url.example.com
```

### `.env.production.example` additions

```
# Optional: Home Assistant URL for uptime monitoring
HOME_ASSISTANT_URL=
```

## Invocation

Run independently: `./deploy/monitoring.sh`

Not called automatically from `gcloud-setup.sh` — monitoring setup is a one-time operation, not part of every deploy.

## Cost

GCP pricing: first 2 uptime checks free, additional checks $0.30/month each. 5 checks = ~$0.90/month.

## Scope exclusions

- No auto-remediation
- No monitoring dashboard
- No changes to existing deploy/backup notifications
