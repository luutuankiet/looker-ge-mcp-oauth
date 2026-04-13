#!/bin/bash
# =============================================================================
# Step 1: Register an OAuth client app on Looker
# =============================================================================
# Creates an OAuth2 client app on your Looker instance that the PKCE proxy
# will use to redirect users for consent.
#
# Run this ONCE per Looker instance. Idempotent — if the app already exists
# with the same GUID, this will return its details.
#
# Requires Looker admin permissions (the API3 creds in .env must belong to an
# admin user).
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found. Copy .env.example and fill it in."; exit 1; }
set -a; source .env; set +a

: "${LOOKERSDK_BASE_URL:?must be set}"
: "${LOOKERSDK_CLIENT_ID:?must be set}"
: "${LOOKERSDK_CLIENT_SECRET:?must be set}"
: "${LOOKER_OAUTH_CLIENT_ID:?must be set}"
: "${PKCE_PROXY_PROJECT:?must be set}"
: "${PKCE_PROXY_REGION:?must be set}"
: "${PKCE_PROXY_FUNCTION_NAME:?must be set}"

API_URL="${LOOKERSDK_BASE_URL%/}/api/4.0"
PROXY_BASE_URL="https://${PKCE_PROXY_REGION}-${PKCE_PROXY_PROJECT}.cloudfunctions.net/${PKCE_PROXY_FUNCTION_NAME}"
REDIRECT_URI="${PROXY_BASE_URL}/callback"

echo "==> Authenticating with Looker as API3 client..."
ACCESS_TOKEN=$(curl -s -X POST "${API_URL}/login" \
  -d "client_id=${LOOKERSDK_CLIENT_ID}" \
  -d "client_secret=${LOOKERSDK_CLIENT_SECRET}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Failed to authenticate. Check LOOKERSDK_CLIENT_ID/SECRET in .env"
  exit 1
fi

echo "==> Registering OAuth client app '${LOOKER_OAUTH_CLIENT_ID}' on ${LOOKERSDK_BASE_URL}"
echo "    redirect_uri: ${REDIRECT_URI}"

PAYLOAD=$(cat <<EOF
{
  "redirect_uri": "${REDIRECT_URI}",
  "display_name": "Gemini Enterprise via PKCE Proxy",
  "description": "OAuth client used by Gemini Enterprise ADK agent (per-user Looker auth via PKCE proxy)",
  "enabled": true
}
EOF
)

RESPONSE=$(curl -s -X POST "${API_URL}/oauth_client_apps/${LOOKER_OAUTH_CLIENT_ID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

echo ""
echo "Response:"
echo "${RESPONSE}" | python3 -m json.tool

echo ""
echo "==> NOTE: If the redirect_uri in the response doesn't match what you expect,"
echo "    update it via the Looker SDK or the API explorer."
echo ""
echo "✅ Step 1 complete. Next: ./scripts/02-deploy-pkce-proxy.sh"
