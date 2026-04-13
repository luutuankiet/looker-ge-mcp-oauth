#!/bin/bash
# =============================================================================
# Convenience: Re-point the GE agent at a new Reasoning Engine
# =============================================================================
# Use this after re-deploying the ADK agent (step 5) when iterating on code.
# Updates only the adkAgentDefinition; leaves authorizationConfig untouched.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; source .env; set +a

: "${GOOGLE_CLOUD_PROJECT:?}"
: "${GE_ENGINE_ID:?}"
: "${AGENT_ID:?}"
: "${REASONING_ENGINE_ID:?must point to the new RE you just deployed}"

PROJECT_NUMBER=$(gcloud projects describe "${GOOGLE_CLOUD_PROJECT}" --format="value(projectNumber)")
TOKEN=$(gcloud auth print-access-token)

URL="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/engines/${GE_ENGINE_ID}/assistants/default_assistant/agents/${AGENT_ID}?updateMask=adkAgentDefinition"

PAYLOAD=$(cat <<EOF
{
  "name": "projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/engines/${GE_ENGINE_ID}/assistants/default_assistant/agents/${AGENT_ID}",
  "adkAgentDefinition": {
    "provisionedReasoningEngine": {
      "reasoningEngine": "${REASONING_ENGINE_ID}"
    }
  }
}
EOF
)

curl -s -X PATCH "${URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${GOOGLE_CLOUD_PROJECT}" \
  -d "${PAYLOAD}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
re = d.get('adkAgentDefinition',{}).get('provisionedReasoningEngine',{}).get('reasoningEngine','?')
print(f'✅ Patched. RE: {re}')
"
