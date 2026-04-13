#!/bin/bash
# =============================================================================
# Step 5: Deploy the ADK agent to Vertex AI Agent Engine
# =============================================================================
# CRITICAL: Use `adk deploy agent_engine` CLI, NOT `agent_engines.create()`
# from the Python SDK.
#
# The CLI generates an `agent_engine_app.py` wrapper with proper entrypoint
# metadata. Without it, GE-initiated sessions (which include a session_id in
# the request) crash with `RuntimeError: Session initialization failed.`
#
# How sessions break with the wrong deploy method:
# - GE sends `streaming_agent_run_with_events` with a session_id
# - ADK template's `VertexAiSessionService.get_session()` returns None for 404
# - The fallback to `_init_session` only triggers on `ClientError`, not None
# - Code hits `if not session: raise RuntimeError("Session initialization failed.")`
# - The CLI's wrapper avoids this code path entirely.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
set -a; source .env; set +a

: "${GOOGLE_CLOUD_PROJECT:?}"
: "${GOOGLE_CLOUD_LOCATION:?}"
: "${MCP_SERVER_URL:?must be set after step 3}"
: "${AUTH_ID:?}"
: "${LOOKERSDK_BASE_URL:?}"

cd adk-agent

# Check uv is installed
if ! command -v uv &>/dev/null; then
  echo "ERROR: uv not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi

# Make sure venv exists with adk CLI
if [ ! -f .venv/bin/adk ]; then
  echo "==> Creating venv and installing dependencies..."
  uv sync
fi

# Bundle a runtime .env into the agent package so dotenv.load_dotenv() finds it
# on Agent Engine. The `adk deploy` CLI copies files inside the package directory
# but NOT files at the repo root.
#
# Grep approach (rather than hardcoded cat) so adding new vars to .env at the
# project root doesn't require editing this script.
grep -E '^(GOOGLE_CLOUD_PROJECT|GOOGLE_CLOUD_LOCATION|LOOKERSDK_|MCP_|AUTH_ID|GE_)' ../.env > looker_ge_agent/.env
echo "==> Bundled runtime env into looker_ge_agent/.env:"
sed 's/^/    /' looker_ge_agent/.env

DISPLAY_NAME="${ADK_DISPLAY_NAME:-looker-mcp-agent}"

echo "==> Deploying ADK agent..."
echo "    Project:      ${GOOGLE_CLOUD_PROJECT}"
echo "    Region:       ${GOOGLE_CLOUD_LOCATION}"
echo "    Display name: ${DISPLAY_NAME}"
echo "    AUTH_ID:      ${AUTH_ID}"
echo "    MCP URL:      ${MCP_SERVER_URL}"
echo ""

# Use a tempfile so we can stream to TTY and capture for parsing
DEPLOY_LOG=$(mktemp)
trap 'rm -f "$DEPLOY_LOG"' EXIT

.venv/bin/adk deploy agent_engine \
  --project "${GOOGLE_CLOUD_PROJECT}" \
  --region "${GOOGLE_CLOUD_LOCATION}" \
  --display_name "${DISPLAY_NAME}" \
  looker_ge_agent 2>&1 | tee "$DEPLOY_LOG"

# Extract the new RE resource name
RE_NAME=$(grep -oE 'projects/[0-9]+/locations/[a-z0-9-]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | tail -1)

if [ -z "$RE_NAME" ]; then
  echo "ERROR: Failed to extract Reasoning Engine name from deploy output"
  exit 1
fi

echo ""
echo "==> Deployed: ${RE_NAME}"

# Persist REASONING_ENGINE_ID into the project root .env (we're in adk-agent/ here)
ENV_FILE="../.env"
if grep -q "^REASONING_ENGINE_ID=" "$ENV_FILE"; then
  sed -i.bak "s|^REASONING_ENGINE_ID=.*|REASONING_ENGINE_ID=${RE_NAME}|" "$ENV_FILE" && rm "${ENV_FILE}.bak"
else
  echo "REASONING_ENGINE_ID=${RE_NAME}" >> "$ENV_FILE"
fi
echo "==> Updated .env: REASONING_ENGINE_ID=${RE_NAME}"
echo ""

# IAM: grant the RE service account Cloud Run Invoker on the toolbox
# (only matters if toolbox is in a different project AND is private)
if [ "${TOOLBOX_PROJECT:-${GOOGLE_CLOUD_PROJECT}}" != "${GOOGLE_CLOUD_PROJECT}" ]; then
  RE_PROJECT_NUMBER=$(echo "$RE_NAME" | cut -d/ -f2)
  RE_SA="service-${RE_PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
  echo "==> Granting Cloud Run Invoker to ${RE_SA} on toolbox..."
  gcloud run services add-iam-policy-binding "${TOOLBOX_SERVICE_NAME}" \
    --project="${TOOLBOX_PROJECT}" \
    --region="${TOOLBOX_REGION}" \
    --member="serviceAccount:${RE_SA}" \
    --role="roles/run.invoker" || echo "WARN: IAM binding failed (may already exist)"
fi

echo ""
echo "✅ Step 5 complete. Update REASONING_ENGINE_ID in .env, then: ./scripts/06-register-ge-agent.sh"
