#!/bin/bash
# =============================================================================
# Step 0a: Enable required GCP APIs
# =============================================================================
# Run this once per project. Idempotent.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found. Copy .env.example and fill it in."; exit 1; }
set -a; source .env; set +a

: "${GOOGLE_CLOUD_PROJECT:?}"

APIS=(
  "aiplatform.googleapis.com"           # Vertex AI Agent Engine
  "discoveryengine.googleapis.com"      # Gemini Enterprise / AgentSpace
  "cloudfunctions.googleapis.com"       # PKCE proxy
  "run.googleapis.com"                  # MCP toolbox + 2nd-gen Cloud Functions
  "cloudbuild.googleapis.com"           # builds for both
  "artifactregistry.googleapis.com"     # required by Cloud Run + 2nd-gen functions
  "iamcredentials.googleapis.com"       # for ID token generation by RE service account
  "storage.googleapis.com"              # for the ADK staging bucket
)

# Also enable on PKCE proxy and toolbox projects if different
PROJECTS=("${GOOGLE_CLOUD_PROJECT}")
[ -n "${PKCE_PROXY_PROJECT:-}" ] && [ "${PKCE_PROXY_PROJECT}" != "${GOOGLE_CLOUD_PROJECT}" ] && PROJECTS+=("${PKCE_PROXY_PROJECT}")
[ -n "${TOOLBOX_PROJECT:-}" ] && [ "${TOOLBOX_PROJECT}" != "${GOOGLE_CLOUD_PROJECT}" ] && [[ ! " ${PROJECTS[*]} " =~ " ${TOOLBOX_PROJECT} " ]] && PROJECTS+=("${TOOLBOX_PROJECT}")

for PROJECT in "${PROJECTS[@]}"; do
  echo "==> Enabling APIs in ${PROJECT}..."
  gcloud services enable "${APIS[@]}" --project="${PROJECT}"
done

echo ""
echo "✅ APIs enabled. Next: ./scripts/00-check-prereqs.sh"
