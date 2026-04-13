import os
from dotenv import load_dotenv

load_dotenv()

# Required at runtime — fail loudly at import time so misconfigured deploys
# crash on startup instead of silently using placeholder values that produce
# confusing 401s and "tool not found" errors downstream.

MCP_SERVER_URL = os.getenv("MCP_SERVER_URL")
if not MCP_SERVER_URL:
    raise RuntimeError(
        "MCP_SERVER_URL env var is not set. The toolbox URL must be bundled into "
        "the agent package via .env (looker_ge_agent/.env) before deploying."
    )

LOOKER_AUTH_STATE_KEY = os.getenv("AUTH_ID")
if not LOOKER_AUTH_STATE_KEY:
    raise RuntimeError(
        "AUTH_ID env var is not set. This must match the authorizationId you "
        "registered in Discovery Engine (e.g. 'looker-oauth') so the agent can "
        "read the per-user OAuth token from session.state[AUTH_ID]."
    )

DEFAULT_MCP_SERVER_MODEL = os.getenv("MCP_SERVER_MODEL", "gemini-2.5-flash")
