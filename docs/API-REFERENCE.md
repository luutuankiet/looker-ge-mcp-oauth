# API Reference: Discovery Engine + Vertex AI Agent Engine

Exact REST schemas for every API call used in setup. The official docs are scattered and incomplete; consider this the definitive reference for this specific use case.

All endpoints assume the `v1alpha` API version of Discovery Engine (`v1` is missing some fields). All require:
```
Authorization: Bearer <gcloud-access-token>
X-Goog-User-Project: <project-id>
```

Project numbers vs project IDs: Discovery Engine uses **project numbers** in resource names (`projects/735108187154/...`), but accepts project IDs in URLs and the `X-Goog-User-Project` header. Get the number with:
```bash
gcloud projects describe <PROJECT_ID> --format="value(projectNumber)"
```

---

## 1. Register an OAuth authorization

**Endpoint**
```
POST https://discoveryengine.googleapis.com/v1alpha/projects/<PROJECT_ID>/locations/global/authorizations?authorizationId=<AUTH_ID>
```

**Body**
```json
{
  "name": "projects/<PROJECT_ID>/locations/global/authorizations/<AUTH_ID>",
  "serverSideOauth2": {
    "clientId": "<oauth-client-id>",
    "clientSecret": "<oauth-client-secret>",
    "authorizationUri": "https://<auth-server>/auth?response_type=code&scope=...",
    "tokenUri": "https://<auth-server>/token"
  }
}
```

**Notes**
- `clientId` and `clientSecret` are sent by GE during the OAuth code-exchange step. The `client_secret` is sent **always**, regardless of any PKCE setting.
- `authorizationUri` is where GE redirects the user's browser. You can include query params like `prompt=consent` or `access_type=offline` here.
- `tokenUri` is where GE POSTs to exchange the auth code. GE always sends `client_id`, `client_secret`, `code`, `redirect_uri`, `grant_type` as form-encoded fields.
- `pkce_verification_enabled: true` is **not** required and may interfere with proxy-handled PKCE. We've found omitting it works better.

**Response** mirrors the request with the resource name canonicalized to use the project number.

**Delete**
```
DELETE https://discoveryengine.googleapis.com/v1alpha/projects/<PROJECT_ID>/locations/global/authorizations/<AUTH_ID>
```
Will return `400 FAILED_PRECONDITION` if any agent's `authorizationConfig` references this resource. Unlink first (see #3).

**List**
```
GET https://discoveryengine.googleapis.com/v1alpha/projects/<PROJECT_ID>/locations/global/authorizations
```

---

## 2. Register a Reasoning Engine (ADK agent) in Gemini Enterprise

**Endpoint**
```
POST https://discoveryengine.googleapis.com/v1alpha/projects/<PROJECT_NUMBER>/locations/global/collections/default_collection/engines/<GE_ENGINE_ID>/assistants/default_assistant/agents?agentId=<AGENT_ID>
```

**Body**
```json
{
  "displayName": "Looker Agent",
  "description": "Looker MCP Agent with per-user OAuth",
  "authorizationConfig": {
    "agentAuthorization": "projects/<PROJECT_NUMBER>/locations/global/authorizations/<AUTH_ID>",
    "toolAuthorizations": [
      "projects/<PROJECT_NUMBER>/locations/global/authorizations/<AUTH_ID>"
    ]
  },
  "adkAgentDefinition": {
    "provisionedReasoningEngine": {
      "reasoningEngine": "projects/<PROJECT_NUMBER>/locations/<REGION>/reasoningEngines/<RE_ID>"
    }
  }
}
```

**Field meanings**
- `agentAuthorization` — when the user opens a chat with this agent, GE runs them through this OAuth flow before the first message
- `toolAuthorizations` — same auth resource is used to inject tokens for any tools the agent calls (in our case, the MCP toolset)
- `provisionedReasoningEngine.reasoningEngine` — full resource name of the Vertex AI Reasoning Engine. **Must use project number, not project ID.**

**Response** state will be `ENABLED` if successful.

---

## 3. Update an agent's Reasoning Engine pointer (most common iteration loop)

```
PATCH https://discoveryengine.googleapis.com/v1alpha/projects/<PROJECT_NUMBER>/locations/global/collections/default_collection/engines/<GE_ENGINE_ID>/assistants/default_assistant/agents/<AGENT_ID>?updateMask=adkAgentDefinition
```

**Body**
```json
{
  "name": "projects/<PROJECT_NUMBER>/locations/global/collections/default_collection/engines/<GE_ENGINE_ID>/assistants/default_assistant/agents/<AGENT_ID>",
  "adkAgentDefinition": {
    "provisionedReasoningEngine": {
      "reasoningEngine": "projects/<PROJECT_NUMBER>/locations/<REGION>/reasoningEngines/<NEW_RE_ID>"
    }
  }
}
```

**`updateMask` values you'll use:**
- `adkAgentDefinition` — re-point to a new Reasoning Engine (after redeploy)
- `authorizationConfig` — change which OAuth authorization is used (or set to `{}` to unlink, e.g. before deletion)
- `displayName,description` — update labels

---

## 4. List existing agents in a GE engine

```
GET https://discoveryengine.googleapis.com/v1alpha/projects/<PROJECT_NUMBER>/locations/global/collections/default_collection/engines/<GE_ENGINE_ID>/assistants/default_assistant/agents
```

Returns a mix of:
- `managedAgentDefinition` agents (Deep Research, Idea Generation, NotebookLM — built-in GE agents)
- `adkAgentDefinition` agents (yours)

---

## 5. Inspect a Reasoning Engine

```
GET https://us-central1-aiplatform.googleapis.com/v1beta1/projects/<PROJECT_ID>/locations/us-central1/reasoningEngines/<RE_ID>
```

**Key fields to check after deploy:**
- `spec.agentFramework` — should be `google-adk`
- `spec.sourceCodeSpec.pythonSpec.entrypointModule` — must NOT be empty (broken deploys have this empty)
- `spec.sourceCodeSpec.pythonSpec.entrypointObject` — should be `adk_app`
- `spec.deploymentSpec.env` — your runtime env vars (MCP_SERVER_URL, AUTH_ID, etc.)
- `spec.effectiveIdentity` — the service account the RE runs as

**List sessions**
```
GET https://us-central1-aiplatform.googleapis.com/v1beta1/projects/<PROJECT_ID>/locations/us-central1/reasoningEngines/<RE_ID>/sessions
```

**Get a single session (to inspect state)**
```
GET https://us-central1-aiplatform.googleapis.com/v1beta1/projects/<PROJECT_ID>/locations/us-central1/reasoningEngines/<RE_ID>/sessions/<SESSION_ID>
```

The `sessionState` field shows what GE injected. For a working OAuth flow, you should see your AUTH_ID as a key with the user's Looker token as the value.

---

## 6. Streaming a query to the Reasoning Engine directly (bypass GE)

Useful for testing the RE in isolation:
```
POST https://us-central1-aiplatform.googleapis.com/v1beta1/projects/<PROJECT_ID>/locations/us-central1/reasoningEngines/<RE_ID>:streamQuery
```

**Body (no session — like the Playground)**
```json
{
  "class_method": "streaming_agent_run_with_events",
  "input": {
    "request_json": "{\"user_id\": \"test-user\", \"message\": {\"role\": \"user\", \"parts\": [{\"text\": \"hello\"}]}}"
  }
}
```

**Body (with session — what GE sends)**
```json
{
  "class_method": "streaming_agent_run_with_events",
  "input": {
    "request_json": "{\"session_id\": \"abc-123\", \"user_id\": \"user@example.com\", \"message\": {\"role\": \"user\", \"parts\": [{\"text\": \"list models\"}]}}"
  }
}
```

The session-bearing form is what fails with `Session initialization failed.` if the RE was deployed via the Python SDK instead of the CLI.

**Response** is newline-delimited JSON, one event per line. Each event has a `content` field with the agent's response parts.

---

## Authorization linkage diagram

```
GE Engine
  └── Assistant (default_assistant)
        └── Agent (looker_mcp_agent)
              ├── adkAgentDefinition.provisionedReasoningEngine.reasoningEngine
              │     → projects/<PROJECT_NUMBER>/locations/us-central1/reasoningEngines/<RE_ID>
              │
              ├── authorizationConfig.agentAuthorization
              │     → projects/<PROJECT_NUMBER>/locations/global/authorizations/looker-oauth
              │
              └── authorizationConfig.toolAuthorizations[]
                    → projects/<PROJECT_NUMBER>/locations/global/authorizations/looker-oauth
                          ├── serverSideOauth2.clientId
                          ├── serverSideOauth2.clientSecret
                          ├── serverSideOauth2.authorizationUri  → PKCE proxy /auth
                          └── serverSideOauth2.tokenUri          → PKCE proxy /token
```

Both `agentAuthorization` and `toolAuthorizations` typically point at the same authorization resource. The first triggers the OAuth flow when the user opens a chat; the second injects the resulting token into tool call contexts.
