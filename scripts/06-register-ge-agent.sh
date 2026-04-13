#!/bin/bash
# =============================================================================
# Step 6: Register the ADK agent in Gemini Enterprise
# =============================================================================
# Tells GE about the agent and links it to:
#   - the deployed Reasoning Engine (adkAgentDefinition.provisionedReasoningEngine)
#   - the OAuth authorization (authorizationConfig.agentAuthorization +
#     toolAuthorizations)
#
# After this, the agent shows up in the GE chat UI under your engine.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; source .env; set +a

: "${GOOGLE_CLOUD_PROJECT:?}"
: "${GE_ENGINE_ID:?}"
: "${AGENT_ID:?}"
: "${AUTH_ID:?}"
: "${REASONING_ENGINE_ID:?must be set after step 5}"

# Get the project NUMBER (not the project ID) — Discovery Engine uses numbers
PROJECT_NUMBER=$(gcloud projects describe "${GOOGLE_CLOUD_PROJECT}" --format="value(projectNumber)")

echo "==> Registering ADK agent '${AGENT_ID}' in GE engine '${GE_ENGINE_ID}'"
echo "    Project number:    ${PROJECT_NUMBER}"
echo "    Reasoning Engine:  ${REASONING_ENGINE_ID}"
echo "    Auth ID:           ${AUTH_ID}"
echo ""

TOKEN=$(gcloud auth print-access-token)

PAYLOAD=$(cat <<EOF
{
  "displayName": "Looker Agent",
  "description": "Looker MCP Agent with per-user OAuth — queries Looker data via MCP Toolbox",
  "authorizationConfig": {
    "agentAuthorization": "projects/${PROJECT_NUMBER}/locations/global/authorizations/${AUTH_ID}",
    "toolAuthorizations": [
      "projects/${PROJECT_NUMBER}/locations/global/authorizations/${AUTH_ID}"
    ]
  },
  "adkAgentDefinition": {
    "provisionedReasoningEngine": {
      "reasoningEngine": "${REASONING_ENGINE_ID}"
    }
  }
}
EOF
)

URL="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/engines/${GE_ENGINE_ID}/assistants/default_assistant/agents?agentId=${AGENT_ID}"

RESPONSE=$(curl -s -X POST "${URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${GOOGLE_CLOUD_PROJECT}" \
  -d "${PAYLOAD}")

if echo "${RESPONSE}" | grep -q '"code": 409'; then
  echo "Agent already exists. To update its Reasoning Engine pointer, run:"
  echo "  ./scripts/99-patch-ge-agent.sh"
else
  echo "${RESPONSE}" | python3 -m json.tool
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "Open your Gemini Enterprise app and chat with the Looker Agent."
echo "First message → OAuth popup → consent → query Looker as that user."
