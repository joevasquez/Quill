#!/bin/bash
# Deploy the Quill AI proxy Cloud Function to GCP.
#
# Prerequisites:
#   1. gcloud CLI installed and authenticated
#   2. Project quill-495210 selected: gcloud config set project quill-495210
#
# Env vars are PATCHED, not replaced (--update-env-vars), so you only export
# what you want to change. ANTHROPIC_API_KEY is therefore only required on a
# first-ever deploy — after that it persists on the function. To drop a
# variable, use: gcloud functions deploy ... --remove-env-vars=NAME
#
# QUILL_PROXY_SECRET is the normal entitlement path: it authenticates the
# proxy to the Athena dashboard, which owns Pro approvals in D1 and is
# administered from the dashboard's Quill Admin tab. It must match the
# worker secret of the same name.
#
# ALLOWED_EMAILS is the break-glass override — a comma-separated list of
# Google accounts that get Pro regardless of the dashboard. At least one of
# the two must be set; the function fails closed without either.
#
# Optional: ENTITLEMENT_URL to point at a different dashboard;
# QUILL_OAUTH_CLIENT_IDS to override the pinned OAuth client audience(s);
# DAILY_REQUEST_LIMIT (default 500 requests/user/day).
#
# Usage:
#   export QUILL_PROXY_SECRET=...
#   bash deploy.sh

set -euo pipefail

PROJECT_ID="quill-495210"
REGION="us-central1"
FUNCTION_NAME="quill-ai-proxy"
RUNTIME="nodejs22"

# gcloud splits env-var flags on commas, but ALLOWED_EMAILS and
# QUILL_OAUTH_CLIENT_IDS are themselves comma-separated lists — use gcloud's
# alternate-delimiter syntax (^:::^) so commas pass through as values.
ENV_VARS=""
add_env() {
  [ -n "${2:-}" ] || return 0
  ENV_VARS="${ENV_VARS}:::$1=$2"
}
add_env ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}"
add_env QUILL_PROXY_SECRET "${QUILL_PROXY_SECRET:-}"
add_env ALLOWED_EMAILS "${ALLOWED_EMAILS:-}"
add_env ENTITLEMENT_URL "${ENTITLEMENT_URL:-}"
add_env QUILL_OAUTH_CLIENT_IDS "${QUILL_OAUTH_CLIENT_IDS:-}"
add_env DAILY_REQUEST_LIMIT "${DAILY_REQUEST_LIMIT:-}"
add_env ANTHROPIC_MODEL "${ANTHROPIC_MODEL:-}"

ENV_FLAG=()
if [ -n "${ENV_VARS}" ]; then
  ENV_FLAG=(--update-env-vars="^:::^${ENV_VARS#:::}")
else
  echo "No env vars exported — deploying code only, keeping the function's existing configuration."
fi

echo "Deploying ${FUNCTION_NAME} to ${PROJECT_ID} (${REGION})..."

gcloud functions deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --runtime="${RUNTIME}" \
  --trigger-http \
  --allow-unauthenticated \
  --entry-point="quill-ai-proxy" \
  "${ENV_FLAG[@]}" \
  --memory=256MB \
  --timeout=60s \
  --source="$(dirname "$0")"

echo ""
echo "Deployed! Function URL:"
echo "  https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME}"
echo ""
echo "Update ProAIProxyClient.proxyURL in the Xcode project if the URL differs."
