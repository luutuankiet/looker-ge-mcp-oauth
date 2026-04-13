#!/bin/bash
# =============================================================================
# Step 3: Deploy the MCP Toolbox to Cloud Run
# =============================================================================
# Deploys the GenAI Toolbox in --prebuilt=looker mode.
#
# CRITICAL: LOOKER_USE_CLIENT_OAUTH must be the HEADER NAME the toolbox should
# read the per-user token from, NOT the boolean "true". Setting it to "true"
# results in the toolbox not reading any header at all and calling Looker
# without credentials — every tool call returns 401.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; source .env; set +a

: "${TOOLBOX_PROJECT:?}"
: "${TOOLBOX_REGION:?}"
: "${TOOLBOX_SERVICE_NAME:?}"
: "${LOOKERSDK_BASE_URL:?}"

echo "==> Deploying MCP Toolbox to Cloud Run..."
echo "    Project:  ${TOOLBOX_PROJECT}"
echo "    Region:   ${TOOLBOX_REGION}"
echo "    Service:  ${TOOLBOX_SERVICE_NAME}"
echo ""

gcloud run deploy "${TOOLBOX_SERVICE_NAME}" \
  --project="${TOOLBOX_PROJECT}" \
  --region="${TOOLBOX_REGION}" \
  --image="us-central1-docker.pkg.dev/database-toolbox/toolbox/toolbox:latest" \
  --args="--prebuilt=looker,--address=0.0.0.0,--port=8080" \
  --port=8080 \
  --no-allow-unauthenticated \
  --set-env-vars="LOOKER_BASE_URL=${LOOKERSDK_BASE_URL},LOOKER_USE_CLIENT_OAUTH=X-Looker-Token,LOOKER_VERIFY_SSL=true"

URL=$(gcloud run services describe "${TOOLBOX_SERVICE_NAME}" \
  --project="${TOOLBOX_PROJECT}" \
  --region="${TOOLBOX_REGION}" \
  --format="value(status.url)")

MCP_URL="${URL}/mcp"

echo ""
echo "==> Toolbox deployed at: ${URL}"
echo "==> MCP endpoint:        ${MCP_URL}"

# Persist MCP_SERVER_URL into .env so subsequent scripts pick it up automatically
if grep -q "^MCP_SERVER_URL=" .env; then
  # macOS-compatible sed in-place
  sed -i.bak "s|^MCP_SERVER_URL=.*|MCP_SERVER_URL=${MCP_URL}|" .env && rm .env.bak
else
  echo "MCP_SERVER_URL=${MCP_URL}" >> .env
fi
echo "==> Updated .env: MCP_SERVER_URL=${MCP_URL}"
echo ""
echo "✅ Step 3 complete. Next: ./scripts/04-register-ge-authorization.sh"
