#!/bin/bash
# =============================================================================
# Step 2: Deploy the PKCE proxy Cloud Function
# =============================================================================
# This is the bridge between Gemini Enterprise (which insists on sending a
# client_secret in the OAuth token exchange) and Looker (which is a public
# PKCE client and rejects requests containing client_secret).
#
# The proxy exposes /auth /callback /token endpoints. GE talks to these as if
# they were Looker's, the proxy strips the bogus client_secret and does a
# clean PKCE exchange with Looker on the backend.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; source .env; set +a

: "${PKCE_PROXY_PROJECT:?}"
: "${PKCE_PROXY_REGION:?}"
: "${PKCE_PROXY_FUNCTION_NAME:?}"
: "${PKCE_PROXY_CLIENT_SECRET:?must be set — use openssl rand -hex 32}"
: "${LOOKERSDK_BASE_URL:?}"
: "${LOOKER_OAUTH_CLIENT_ID:?}"

PROXY_BASE_URL="https://${PKCE_PROXY_REGION}-${PKCE_PROXY_PROJECT}.cloudfunctions.net/${PKCE_PROXY_FUNCTION_NAME}"

echo "==> Deploying PKCE proxy Cloud Function..."
echo "    Project:  ${PKCE_PROXY_PROJECT}"
echo "    Region:   ${PKCE_PROXY_REGION}"
echo "    Function: ${PKCE_PROXY_FUNCTION_NAME}"
echo "    Looker:   ${LOOKERSDK_BASE_URL}"
echo "    Looker client_id: ${LOOKER_OAUTH_CLIENT_ID}"
echo ""

cd pkce-proxy

gcloud functions deploy "${PKCE_PROXY_FUNCTION_NAME}" \
  --project="${PKCE_PROXY_PROJECT}" \
  --region="${PKCE_PROXY_REGION}" \
  --runtime=python311 \
  --trigger-http \
  --allow-unauthenticated \
  --entry-point=main \
  --source=. \
  --set-env-vars="LOOKER_BASE_URL=${LOOKERSDK_BASE_URL},LOOKER_CLIENT_ID=${LOOKER_OAUTH_CLIENT_ID},PROXY_CLIENT_SECRET=${PKCE_PROXY_CLIENT_SECRET},PROXY_BASE_URL=${PROXY_BASE_URL}" \
  --memory=256MB \
  --timeout=60s

echo ""
echo "==> Proxy deployed at: ${PROXY_BASE_URL}"
echo ""
echo "✅ Step 2 complete. Next: ./scripts/03-deploy-toolbox.sh"
