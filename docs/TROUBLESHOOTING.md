# Troubleshooting

Every error we hit during integration, with root causes and fixes. If you're following the README setup and something silently fails, this is the doc you want.

---

## 1. `RuntimeError: Session initialization failed.`

### Symptom
- GE Console: chat shows blank response, no error
- RE logs (Cloud Logging, filter `resource.labels.reasoning_engine_id=<your-RE>`):
  ```
  ERROR: Error during stream generation: Session initialization failed.
  Traceback (most recent call last):
    File ".../vertexai/preview/reasoning_engines/templates/adk.py", line 1035, in _invoke_agent_async
      raise RuntimeError("Session initialization failed.")
  ```

### Root cause
The agent was deployed using `agent_engines.create()` from the Python SDK (e.g. via the reference impl's `deployment/deploy.py`). That deployment path doesn't register the entrypoint module/object metadata properly, and the runtime falls into a code path that expects `VertexAiSessionService.get_session()` to raise `ClientError` for missing sessions — but it actually returns `None`. The fallback to `_init_session()` never triggers, and you crash.

You can verify this by inspecting the Reasoning Engine spec:
```bash
gcloud ai reasoning-engines describe <RE_ID> --project=<PROJ> --region=us-central1 \
  --format="value(spec.sourceCodeSpec.pythonSpec.entrypointModule,spec.sourceCodeSpec.pythonSpec.entrypointObject)"
```
A broken deploy returns blank fields. A working deploy returns something like `looker_ge_agent_tmp20260413_134922.agent_engine_app` and `adk_app`.

### Fix
Redeploy using the `adk deploy agent_engine` CLI:
```bash
adk deploy agent_engine \
  --project=<PROJ> \
  --region=us-central1 \
  --display_name=looker-mcp-agent \
  ./looker_ge_agent
```

The CLI generates a proper `agent_engine_app.py` wrapper that the Agent Engine runtime understands. The Python SDK path is broken for ADK agents that need to handle externally-managed sessions (which is what GE does).

### Side effect
The CLI's wrapper does `from .agent import root_agent`, expecting `agent.py` at the package root. If your `root_agent` lives in a subpackage (`looker_ge_agent/looker_mcp_agent/agent.py`), add a one-line shim:
```python
# looker_ge_agent/agent.py
from .looker_mcp_agent.agent import root_agent
```
Otherwise the deploy will succeed but the RE will fail to start with `ModuleNotFoundError: No module named 'looker_ge_agent_tmp....agent'`.

---

## 2. Looker returns `401 Requires authentication` or `404 Sinatra::NotFound` on every tool call

### Symptom
- GE chat: agent responds "I am unable to retrieve the explores at this time due to an authentication error"
- RE Playground (Events tab): tool calls return text like
  ```
  error making get_models request: response_error, statusCode: 401, message: {"message":"Requires authentication"...}
  ```
- The OAuth popup fires successfully, you consent, but the agent still can't query Looker

### Root cause A: Toolbox header config wrong
The MCP toolbox doesn't know which header to read the user's OAuth token from. Check the Cloud Run service env vars:
```bash
gcloud run services describe toolbox-oauth --project=<PROJ> --region=us-central1 \
  --format="value(spec.template.spec.containers[0].env)"
```

If you see:
```
LOOKER_USE_CLIENT_OAUTH=true
```
**That's wrong.** The toolbox treats this as a string for the `tools.yaml` `use_client_oauth` field, which expects a header name. With `true`, the toolbox doesn't read any header at all and calls Looker without credentials.

### Fix A
```bash
gcloud run services update toolbox-oauth \
  --project=<PROJ> --region=us-central1 \
  --update-env-vars="LOOKER_USE_CLIENT_OAUTH=X-Looker-Token"
```

### Root cause B: GE PKCE direct exchange (no proxy)
You registered the OAuth authorization with `authorizationUri` and `tokenUri` pointing **directly** at Looker (`https://your-instance.cloud.looker.com/auth` and `/api/token`), with `pkce_verification_enabled: true`.

This **does not work**. GE's `serverSideOauth2` always sends `client_secret` in the token exchange. Looker's `/api/token` is a public PKCE endpoint that doesn't accept a `client_secret`. The exchange technically returns a 200 but the token is malformed/invalid; subsequent calls return 404 `Sinatra::NotFound`.

You can verify by extracting the token from the session state and testing it directly:
```bash
TOKEN=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: <PROJ>" \
  "https://us-central1-aiplatform.googleapis.com/v1beta1/projects/<PROJ>/locations/us-central1/reasoningEngines/<RE_ID>/sessions" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sessions'][0]['sessionState']['<AUTH_ID>'])")
curl -s -H "Authorization: token ${TOKEN}" "https://your-instance.cloud.looker.com/api/4.0/me"
```
If you see `Sinatra::NotFound` → token is broken → GE exchange is broken → you need the proxy.

### Fix B
Deploy the PKCE proxy (step 2 in the README), and re-register the GE authorization to point at it (step 4). The proxy absorbs GE's `client_secret`, validates it as a shared proxy credential, then does a clean public-client PKCE exchange with Looker on the backend.

---

## 3. OAuth popup never appears in GE Console

### Symptom
You patched the GE agent and updated the authorizationConfig, but when you chat in the GE Console, the agent runs and reports auth errors — there's no consent popup.

### Root cause
GE caches OAuth consent state **per (user, AUTH_ID)**. Once you've authenticated (or attempted to authenticate) for a given `AUTH_ID`, GE assumes you have a token and won't re-prompt — even if the token is dead, even if you delete and re-create the authorization resource, even in incognito mode (because GE's cache is server-side, not browser-side).

There is no API to revoke or invalidate the cached consent.

### Fix
Change `AUTH_ID` to a new value (e.g. `looker-oauth-v2`), then:
1. Re-register the authorization with the new ID (step 4 in README)
2. Update `AUTH_ID` in `looker_ge_agent/.env` and re-deploy the agent (step 5) so the agent reads the token from the new state key
3. Re-link the agent to the new authorization (step 6 in README)
4. Open a new chat in GE Console — the popup will fire because GE has zero cached state for the new AUTH_ID

### Alternative
If you don't want to redeploy the agent, you can instead delete and re-create the Looker OAuth client app with a different `client_guid`. GE's per-user cache is keyed on the auth resource, so a new resource forces fresh consent.

---

## 4. Cross-project: RE can't reach the toolbox (Cloud Run 403)

### Symptom
RE logs show 403 errors when calling the toolbox URL. Or the agent response says "Cloud Run service unavailable" / network errors.

### Root cause
The toolbox is in a different GCP project than the Reasoning Engine, the toolbox is private (no `--allow-unauthenticated`), and the RE service account doesn't have `roles/run.invoker` on it.

### Fix
First find the RE service account. The format is `service-<PROJECT_NUMBER>@gcp-sa-aiplatform-re.iam.gserviceaccount.com`, where `PROJECT_NUMBER` is the **numeric** project number of the project containing the Reasoning Engine.

```bash
RE_PROJ_NUM=$(gcloud projects describe <RE_PROJECT_ID> --format="value(projectNumber)")

gcloud run services add-iam-policy-binding toolbox-oauth \
  --project=<TOOLBOX_PROJECT> \
  --region=us-central1 \
  --member="serviceAccount:service-${RE_PROJ_NUM}@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

**Important**: the RE service account doesn't exist in IAM until **after** you've deployed your first Reasoning Engine in the target project. So order matters: deploy the RE first, then grant IAM, then test.

---

## 5. `agent_engine.pkl` 403 during deploy

### Symptom
`adk deploy` or `deployment/deploy.py` fails partway with:
```
google.api_core.exceptions.Forbidden: 403 GET https://storage.googleapis.com/.../agent_engine.pkl
... does not have storage.objects.get access ...
```

### Root cause
The deploy script created a fresh staging bucket but the user running the deploy doesn't have `storage.objectAdmin` on it. The bucket creation succeeds (project-level perms), but the readback for verification fails.

### Fix
```bash
gsutil iam ch user:your-email@example.com:objectAdmin gs://<PROJECT>-adk-staging
```

Then re-run the deploy.

---

## 6. Toolbox returns `UNEXPECTED_TOOL_CALL` errors

### Symptom
RE Playground (Events tab) shows:
```
"error_code": "UNEXPECTED_TOOL_CALL",
"error_message": "Unexpected tool call: print(looker_mcp_agent.list_looker_models())"
```

### Root cause
The agent tried to call a tool that doesn't exist in its toolset. This means the MCP toolset failed to load any tools at all from the toolbox, so when Gemini hallucinates a tool call, it gets back `UNEXPECTED_TOOL_CALL`.

The most common reason for the toolset failing to load: the `MCP_SERVER_URL` env var on the deployed Reasoning Engine is unset or wrong. The agent's `constants.py` falls back to a placeholder string, the MCPToolset tries to connect to that placeholder, fails, and registers zero tools.

### Fix
Verify the deployed RE has the env vars you expect:
```bash
gcloud ai reasoning-engines describe <RE_ID> --project=<PROJ> --region=us-central1 \
  --format="json" | jq '.spec.deploymentSpec.env'
```

If `MCP_SERVER_URL` is missing or wrong, the issue is your deploy step didn't bundle `.env` into the agent package. The `adk deploy` CLI reads the `.env` file from **inside** the agent package directory (e.g. `looker_ge_agent/.env`), not from the project root. Fix: copy `.env` into the package dir before deploying.

---

## 7. `Authorization is linked to a resource and cannot be deleted`

### Symptom
You try to delete the OAuth authorization to recreate it:
```bash
curl -X DELETE .../authorizations/looker-oauth
```
And get:
```json
{"error":{"code":400,"message":"Authorization is linked to a resource and cannot be deleted: ..."}}
```

### Root cause
Discovery Engine refuses to delete an authorization that's still referenced by an agent's `authorizationConfig`.

### Fix
Unlink first:
```bash
curl -X PATCH "https://discoveryengine.googleapis.com/v1alpha/projects/<NUM>/locations/global/collections/default_collection/engines/<ENGINE_ID>/assistants/default_assistant/agents/<AGENT_ID>?updateMask=authorizationConfig" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: <PROJ>" \
  -d '{"name":"projects/<NUM>/.../agents/<AGENT_ID>","authorizationConfig":{}}'
```
Then delete, recreate, and re-link.

---

## 8. Generic debugging tips

### Inspect a session and its state
```bash
TOKEN=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: <PROJ>" \
  "https://us-central1-aiplatform.googleapis.com/v1beta1/projects/<PROJ>/locations/us-central1/reasoningEngines/<RE_ID>/sessions" \
  | python3 -m json.tool
```

The `sessionState` field shows what GE injected. If `looker-oauth` (or your AUTH_ID) is missing, GE didn't trigger OAuth. If it's present but the token is bad, the proxy or the toolbox is the problem.

### Test a token directly against Looker
```bash
curl -s -H "Authorization: token <TOKEN>" "https://your-instance.cloud.looker.com/api/4.0/me"
```
- 200 + user data → token is valid
- `Sinatra::NotFound` → token is malformed (PKCE exchange failed)
- `Requires authentication` → token is genuinely expired/invalid

### Test the toolbox directly
```bash
ID_TOKEN=$(gcloud auth print-identity-token --audiences=https://toolbox-oauth-XXX.run.app)
LOOKER_TOKEN="..."  # a fresh valid token

echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_models","arguments":{}}}' \
  | curl -s -X POST "https://toolbox-oauth-XXX.run.app/mcp" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ID_TOKEN" \
    -H "X-Looker-Token: token $LOOKER_TOKEN" \
    --data @-
```
Note: `gcloud auth print-identity-token --audiences` only works for service account credentials, not user credentials. If you're running as a user, the toolbox needs to be `--allow-unauthenticated` or you need to impersonate a service account.

### Read RE runtime logs
```bash
gcloud logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine" AND resource.labels.reasoning_engine_id="<RE_ID>"' \
  --project=<PROJ> --limit=30 --freshness=15m --order=asc \
  --format="value(timestamp,severity,textPayload)"
```

### Read PKCE proxy logs
```bash
gcloud functions logs read looker-pkce-proxy --project=<PROJ> --region=us-central1 --limit=30
```
Look for `[/auth]`, `[/callback]`, `[/token]` log lines and the Looker response status.

### Read toolbox logs
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="toolbox-oauth"' \
  --project=<PROJ> --limit=30 --freshness=15m --order=asc
```
