#!/bin/bash
# Deploy the Quill AI proxy Cloud Function to GCP.
#
# Prerequisites:
#   1. gcloud CLI installed and authenticated
#   2. ANTHROPIC_API_KEY set in your environment (or pass as --set-env-vars)
#   3. Project quill-495210 selected: gcloud config set project quill-495210
#
# ALLOWED_EMAILS is REQUIRED: a comma-separated whitelist of Google accounts
# that can use the proxy. The function fails closed without it.
#
# Optional: QUILL_OAUTH_CLIENT_IDS to override the pinned OAuth client
# audience(s); DAILY_REQUEST_LIMIT (default 500 requests/user/day).
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   export ALLOWED_EMAILS="you@gmail.com,friend@gmail.com"
#   bash deploy.sh

set -euo pipefail

PROJECT_ID="quill-495210"
REGION="us-central1"
FUNCTION_NAME="quill-ai-proxy"
RUNTIME="nodejs20"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Error: ANTHROPIC_API_KEY environment variable is required"
  exit 1
fi
if [ -z "${ALLOWED_EMAILS:-}" ]; then
  echo "Error: ALLOWED_EMAILS environment variable is required (the proxy fails closed without it)"
  exit 1
fi

ENV_VARS="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY},ALLOWED_EMAILS=${ALLOWED_EMAILS}"
if [ -n "${QUILL_OAUTH_CLIENT_IDS:-}" ]; then
  ENV_VARS="${ENV_VARS},QUILL_OAUTH_CLIENT_IDS=${QUILL_OAUTH_CLIENT_IDS}"
fi
if [ -n "${DAILY_REQUEST_LIMIT:-}" ]; then
  ENV_VARS="${ENV_VARS},DAILY_REQUEST_LIMIT=${DAILY_REQUEST_LIMIT}"
fi
if [ -n "${ANTHROPIC_MODEL:-}" ]; then
  ENV_VARS="${ENV_VARS},ANTHROPIC_MODEL=${ANTHROPIC_MODEL}"
fi

echo "Deploying ${FUNCTION_NAME} to ${PROJECT_ID} (${REGION})..."

gcloud functions deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --runtime="${RUNTIME}" \
  --trigger-http \
  --allow-unauthenticated \
  --entry-point="quill-ai-proxy" \
  --set-env-vars="${ENV_VARS}" \
  --memory=256MB \
  --timeout=60s \
  --source="$(dirname "$0")"

echo ""
echo "Deployed! Function URL:"
echo "  https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${FUNCTION_NAME}"
echo ""
echo "Update ProAIProxyClient.proxyURL in the Xcode project if the URL differs."
