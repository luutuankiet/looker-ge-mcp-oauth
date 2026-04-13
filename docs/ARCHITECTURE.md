# Architecture deep dive

The full chain of components, what each one does, and where things break.

---

## Components

### 1. Looker
Standard Looker instance. We register a single OAuth2 client app on it (via the `/api/4.0/oauth_client_apps/{guid}` endpoint) whose `redirect_uri` points at the **PKCE proxy's `/callback` endpoint**, not directly at GE.

The OAuth client app is in **PKCE / public-client mode** — it has no client_secret on the Looker side. Looker treats it as a public client and requires a `code_verifier` (PKCE) on the token exchange instead of a `client_secret`.

### 2. PKCE Proxy (Cloud Function)
A small Python HTTP function with three endpoints (`/auth`, `/callback`, `/token`). It exists because of one fundamental incompatibility:

> **GE's `serverSideOauth2` is designed for confidential OAuth clients.** It always sends `client_secret` in the token exchange, regardless of any PKCE setting. **Looker's CORS OAuth (`/api/token`) is a public client endpoint.** It rejects requests containing `client_secret`.

The proxy bridges these two models:

#### `/auth` (entry point)
GE redirects the user's browser here. The proxy:
1. Generates a PKCE `code_verifier` and `code_challenge`
2. Stores nothing locally (stateless — see below)
3. Redirects to Looker `/auth` with the proxy's Looker `client_id` and `code_challenge`

#### `/callback` (Looker → proxy)
After the user consents on Looker, Looker redirects here with an auth `code`. The proxy:
1. **Wraps** the original `code` together with the `code_verifier` into a single opaque token (e.g. base64-encoded JSON `{code, code_verifier}`)
2. Redirects to GE's OAuth redirect URI (`https://vertexaisearch.cloud.google.com/oauth-redirect`) with this wrapped code

This wrapping is how the proxy stays stateless — instead of storing the `code_verifier` in a database keyed by some session ID, it just smuggles it through GE inside the auth code.

#### `/token` (GE → proxy)
GE POSTs here to exchange the wrapped code. The proxy:
1. Validates the `client_secret` against `PROXY_CLIENT_SECRET` (this is the only place this secret matters — it prevents random callers from using the proxy)
2. **Unwraps** the code to recover the real Looker code + the `code_verifier`
3. POSTs to Looker's `/api/token` with `client_id`, `code`, `code_verifier`, `redirect_uri`, and `grant_type` — but **NOT** `client_secret`
4. Returns Looker's response (the access token) to GE

#### Refresh tokens
The proxy supports `grant_type=refresh_token` and forwards refresh requests to Looker. We use `access_type=offline&prompt=consent` in the auth URI to ask Looker for a refresh token, but Looker may or may not honor it depending on instance config. **Note: GE may not actually use the refresh token even when present** — see TROUBLESHOOTING.md #3 for the per-user OAuth caching gotcha.

### 3. MCP Toolbox (Cloud Run)
The [Google Cloud GenAI Toolbox for Databases](https://github.com/googleapis/genai-toolbox), deployed in `--prebuilt=looker` mode. Exposes an MCP-compatible HTTP endpoint (`/mcp`) with tools like `get_models`, `get_explores`, `get_dimensions`, `query`, `make_dashboard`, etc.

In per-user OAuth mode, it expects to receive each user's Looker token in a custom HTTP header (default `X-Looker-Token`) and forwards it as the bearer credential when calling Looker.

**Critical config**:
```bash
LOOKER_BASE_URL=https://your-instance.cloud.looker.com
LOOKER_USE_CLIENT_OAUTH=X-Looker-Token   # ← header name, NOT "true"
LOOKER_VERIFY_SSL=true
```

The toolbox is typically deployed `--no-allow-unauthenticated` and requires a Google ID token in the `Authorization: Bearer` header for Cloud Run access. The ADK agent fetches this ID token at request time (via `google.oauth2.id_token.fetch_id_token`) using the Reasoning Engine's runtime service account.

### 4. Vertex AI Agent Engine (Reasoning Engine)
Hosts the deployed ADK agent. Each Reasoning Engine is a long-running service that the Discovery Engine / Gemini Enterprise calls via `streaming_agent_run_with_events`.

**Deploy method matters.** Use `adk deploy agent_engine` CLI. Do NOT use `agent_engines.create()` from the Python SDK — see TROUBLESHOOTING.md #1.

The deployed agent code is `looker_ge_agent/looker_mcp_agent/agent.py`, which:
- Builds a `google.adk.Agent` with a `Gemini` model
- Attaches an `MCPToolset` with `StreamableHTTPConnectionParams` pointing at the toolbox `/mcp` URL
- Provides a `header_provider` callback (`set_header_tokens`) that runs on every MCP request and produces the headers

**`set_header_tokens` does two things:**
1. Reads the Looker OAuth token from `session.state[AUTH_ID]` (where `AUTH_ID` is the env var matching the registered authorization resource ID), formats it as `X-Looker-Token: token <token>`
2. Fetches a fresh Google ID token for the toolbox Cloud Run audience, formats it as `Authorization: Bearer <id_token>`

Both headers are returned. The MCPToolset attaches them to the outbound HTTP request to the toolbox. The toolbox uses the `Authorization` header to authenticate the Cloud Run request and the `X-Looker-Token` header to authenticate as the user against Looker.

### 5. Gemini Enterprise (Discovery Engine)
The user-facing chat product. Manages:
- The chat UI
- User identity / SSO
- The OAuth flow (it triggers the popup, exchanges codes via the configured `tokenUri`, caches the resulting token per (user, AUTH_ID))
- Routing chat messages to the configured Reasoning Engine via `streaming_agent_run_with_events`
- Injecting the cached OAuth token into the agent's session state under the AUTH_ID key

Configured via two Discovery Engine resources:
- An **Authorization** (`projects/<num>/locations/global/authorizations/<auth_id>`) with the `serverSideOauth2` config
- An **Agent** (`projects/<num>/.../engines/<engine_id>/assistants/default_assistant/agents/<agent_id>`) that links to the Reasoning Engine and the Authorization

---

## End-to-end request flow

A user sending "list the looker models" produces this sequence:

1. **User** opens GE chat, picks the Looker Agent, types "list the looker models"
2. **GE** checks the agent's `authorizationConfig.agentAuthorization`. If the user has no cached token for this `AUTH_ID`, it triggers the OAuth flow:
   1. Browser redirected to `serverSideOauth2.authorizationUri` — i.e. PKCE proxy `/auth`
   2. Proxy generates PKCE verifier, redirects to Looker `/auth`
   3. User sees Looker's consent screen, approves
   4. Looker redirects to proxy `/callback` with auth code
   5. Proxy wraps code + verifier, redirects to GE's OAuth redirect URI
   6. GE POSTs to proxy `/token` with the wrapped code + bogus `client_secret`
   7. Proxy validates secret, unwraps code, exchanges with Looker `/api/token` (NO secret), returns access token to GE
   8. GE caches the token keyed on (user, AUTH_ID)
3. **GE** POSTs to the Reasoning Engine's `streamQuery` endpoint:
   ```json
   {
     "class_method": "streaming_agent_run_with_events",
     "input": {
       "request_json": "{\"session_id\": \"...\", \"user_id\": \"user@example.com\", \"message\": {...}, \"authorizations\": {\"looker-oauth\": {\"access_token\": \"<looker_token>\"}}}"
     }
   }
   ```
4. **Reasoning Engine** (specifically, the ADK template wrapper) handles the `streaming_agent_run_with_events` call:
   1. Parses the request_json
   2. Looks up or creates the session via `VertexAiSessionService` (this is where broken deploys crash — see TROUBLESHOOTING.md #1)
   3. Calls `_init_session` which iterates `request.authorizations` and writes `auth.access_token` into `session.state[auth_id]`
   4. Invokes the ADK runner with the session and the user's message
5. **ADK Agent** runs, Gemini decides it needs `get_models`, calls the MCP tool
6. **MCPToolset's `_execute_with_session`** invokes `set_header_tokens(readonly_context)`:
   1. Reads `session.state["looker-oauth"]` → gets the user's Looker token
   2. Formats as `X-Looker-Token: token <looker_token>`
   3. Fetches a Google ID token for the toolbox Cloud Run URL
   4. Returns `{"X-Looker-Token": "...", "Authorization": "Bearer <id_token>"}`
7. **MCPToolset** sends an HTTP POST to `<toolbox_url>/mcp` with:
   - `Authorization: Bearer <id_token>` for Cloud Run auth
   - `X-Looker-Token: token <looker_token>` for the toolbox to forward to Looker
   - Body: JSON-RPC MCP protocol message `{"method": "tools/call", "params": {"name": "get_models", ...}}`
8. **MCP Toolbox** (Cloud Run):
   1. Validates the ID token (Cloud Run does this automatically)
   2. Reads `LOOKER_USE_CLIENT_OAUTH` env var → `X-Looker-Token` → reads that header
   3. Strips `token ` prefix if present, uses the value as the bearer credential when calling Looker
   4. Calls `https://your-instance.cloud.looker.com/api/4.0/lookml_models` with `Authorization: token <looker_token>`
9. **Looker** authenticates the request **as the end user**, applies that user's permissions, returns the list of models they have access to
10. The result flows back: Looker → Toolbox → ADK MCP tool → ADK agent → Gemini decides this is the answer → streamed response → GE → user

The whole point of this architecture: step 9 happens with the **user's** identity, not a service account. Two users querying the same agent get different results based on their Looker permissions.

---

## What can go wrong at each step

| Step | Failure mode | Fix |
|------|-------------|-----|
| 2.1-2.7 | OAuth popup never appears | Change AUTH_ID; GE caches per (user, auth_id) |
| 2.7 | Token exchange returns 200 but token is invalid | Looker rejects `client_secret` in PKCE — use the proxy |
| 4.2 | `Session initialization failed` | Use `adk deploy agent_engine` CLI, not Python SDK |
| 6 | `set_header_tokens` not called or token missing from state | Check session state via API; check AUTH_ID env var matches the auth_id |
| 7 | Cloud Run 403 | Grant RE service account `roles/run.invoker` |
| 8.2 | Toolbox calls Looker without credentials → 401 | `LOOKER_USE_CLIENT_OAUTH` must be the header name, not `true` |
| 9 | `Sinatra::NotFound` from Looker | Token is malformed (PKCE exchange broken upstream) |

See TROUBLESHOOTING.md for symptoms, root causes, and exact fixes.
