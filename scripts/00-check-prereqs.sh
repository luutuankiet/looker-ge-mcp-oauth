#!/bin/bash
# =============================================================================
# Step 0b: Sanity-check prerequisites
# =============================================================================
# Catches the most common first-run problems before they produce confusing
# errors deeper in the pipeline.
# =============================================================================

set -uo pipefail

cd "$(dirname "$0")/.."

ERRORS=0
warn() { echo "  ⚠️  $1"; ERRORS=$((ERRORS+1)); }
ok() { echo "  ✅ $1"; }

echo "==> Checking prerequisites..."

# .env exists
if [ -f .env ]; then
  ok ".env present"
  set -a; source .env; set +a
else
  warn ".env not found — copy .env.example and fill it in"
fi

# Required CLIs
for cmd in gcloud uv python3 curl jq; do
  if command -v "$cmd" &>/dev/null; then
    ok "${cmd} installed"
  else
    if [ "$cmd" = "jq" ]; then
      warn "${cmd} not installed (optional but useful — brew install jq)"
    else
      warn "${cmd} not installed"
    fi
  fi
done

# gcloud user auth
if gcloud auth print-access-token &>/dev/null; then
  USER=$(gcloud config get-value account 2>/dev/null)
  ok "gcloud authenticated as ${USER}"
else
  warn "gcloud not authenticated — run: gcloud auth login"
fi

# Application Default Credentials (needed by adk deploy)
if gcloud auth application-default print-access-token &>/dev/null; then
  ok "Application Default Credentials present"
else
  warn "ADC not set — run: gcloud auth application-default login"
fi

# Required env vars
for v in GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION LOOKERSDK_BASE_URL LOOKER_OAUTH_CLIENT_ID PKCE_PROXY_CLIENT_SECRET GE_ENGINE_ID AUTH_ID AGENT_ID; do
  if [ -n "${!v:-}" ]; then
    ok "${v} set"
  else
    warn "${v} not set in .env"
  fi
done

# Verify project exists and user has access
if [ -n "${GOOGLE_CLOUD_PROJECT:-}" ]; then
  if gcloud projects describe "${GOOGLE_CLOUD_PROJECT}" &>/dev/null; then
    NUM=$(gcloud projects describe "${GOOGLE_CLOUD_PROJECT}" --format="value(projectNumber)")
    ok "Project ${GOOGLE_CLOUD_PROJECT} accessible (number: ${NUM})"
  else
    warn "Cannot access project ${GOOGLE_CLOUD_PROJECT}"
  fi
fi

# Check that the GE engine actually exists
if [ -n "${GE_ENGINE_ID:-}" ] && [ -n "${GOOGLE_CLOUD_PROJECT:-}" ]; then
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "X-Goog-User-Project: ${GOOGLE_CLOUD_PROJECT}" \
    "https://discoveryengine.googleapis.com/v1alpha/projects/${GOOGLE_CLOUD_PROJECT}/locations/global/collections/default_collection/engines/${GE_ENGINE_ID}")
  if [ "$STATUS" = "200" ]; then
    ok "GE engine ${GE_ENGINE_ID} exists"
  else
    warn "GE engine ${GE_ENGINE_ID} not found (HTTP ${STATUS}) — create one in the GE console first"
  fi
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "✅ All prereqs OK. Next: ./scripts/01-register-looker-oauth-app.sh"
else
  echo "❌ ${ERRORS} issues found above. Fix them before proceeding."
  exit 1
fi
