#!/bin/bash
# =============================================================================
# Step 4: Register the OAuth authorization in Discovery Engine
# =============================================================================
# This tells Gemini Enterprise: "when a user invokes the agent, run them
# through this OAuth flow first, and inject the resulting token into the
# agent's session state under this AUTH_ID key."
#
# CRITICAL CONFIG NOTES:
# - clientId/clientSecret here are the PROXY's credentials, not Looker's
# - authorizationUri/tokenUri point at the PROXY, not Looker directly
# - DO NOT set pkce_verification_enabled — the proxy handles PKCE itself
# - GE caches OAuth state per (user, AUTH_ID). To force re-consent during
#   development, change AUTH_ID in .env (e.g. looker-oauth-v2) and re-run
#   this script + 06-register-ge-agent.sh.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; source .env; set +a

: "${GOOGLE_CLOUD_PROJECT:?}"
: "${AUTH_ID:?}"
: "${PKCE_PROXY_PROJECT:?}"
: "${PKCE_PROXY_REGION:?}"
: "${PKCE_PROXY_FUNCTION_NAME:?}"
: "${PKCE_PROXY_CLIENT_ID:?}"
: "${PKCE_PROXY_CLIENT_SECRET:?}"

PROXY_BASE_URL="https://${PKCE_PROXY_REGION}-${PKCE_PROXY_PROJECT}.cloudfunctions.net/${PKCE_PROXY_FUNCTION_NAME}"

echo "==> Registering OAuth authorization '${AUTH_ID}' in Discovery Engine"
echo "    Project:    ${GOOGLE_CLOUD_PROJECT}"
echo "    Auth ID:    ${AUTH_ID}"
echo "    Proxy URL:  ${PROXY_BASE_URL}"
echo ""

TOKEN=$(gcloud auth print-access-token)

PAYLOAD=$(cat <<EOF
{
  "name": "projects/${GOOGLE_CLOUD_PROJECT}/locations/global/authorizations/${AUTH_ID}",
  "serverSideOauth2": {
    "clientId": "${PKCE_PROXY_CLIENT_ID}",
    "clientSecret": "${PKCE_PROXY_CLIENT_SECRET}",
    "authorizationUri": "${PROXY_BASE_URL}/auth?response_type=code&scope=cors_api&access_type=offline&prompt=consent",
    "tokenUri": "${PROXY_BASE_URL}/token"
  }
}
EOF
)

URL="https://discoveryengine.googleapis.com/v1alpha/projects/${GOOGLE_CLOUD_PROJECT}/locations/global/authorizations?authorizationId=${AUTH_ID}"

# Try to create; if it exists, this returns 409
RESPONSE=$(curl -s -X POST "${URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${GOOGLE_CLOUD_PROJECT}" \
  -d "${PAYLOAD}")

# Robust JSON-based 409 detection (works for both compact and spaced JSON)
IS_CONFLICT=$(echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    sys.exit(0 if d.get('error',{}).get('code') == 409 else 1)
except Exception:
    sys.exit(1)
" && echo yes || echo no)

if [ "$IS_CONFLICT" = "yes" ]; then
  echo "Authorization '${AUTH_ID}' already exists."
  echo ""
  echo "To force re-consent during development, the easiest path is to use a NEW auth_id"
  echo "(GE caches OAuth state per (user, auth_id), with no API to invalidate it):"
  echo "  1. Edit .env: AUTH_ID=looker-oauth-v2"
  echo "  2. Re-run this script"
  echo "  3. Re-deploy the agent (script 05) so it reads the new AUTH_ID env var"
  echo "  4. Re-link via script 06 (or 99-patch-ge-agent.sh)"
  echo ""
  echo "To delete in-place (must unlink from agents first):"
  echo "  curl -X DELETE -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\"
  echo "    -H \"X-Goog-User-Project: ${GOOGLE_CLOUD_PROJECT}\" \\"
  echo "    \"https://discoveryengine.googleapis.com/v1alpha/projects/${GOOGLE_CLOUD_PROJECT}/locations/global/authorizations/${AUTH_ID}\""
else
  echo "${RESPONSE}" | python3 -m json.tool
fi

echo ""
echo "✅ Step 4 complete. Next: ./scripts/05-deploy-adk-agent.sh"
