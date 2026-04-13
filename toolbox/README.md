# MCP Toolbox

We use the prebuilt Looker mode of the [Google Cloud GenAI Toolbox for Databases](https://github.com/googleapis/genai-toolbox), so there's nothing to build here. The deployment is handled by `../scripts/03-deploy-toolbox.sh`.

## Image
```
us-central1-docker.pkg.dev/database-toolbox/toolbox/toolbox:latest
```

## Args
```
--prebuilt=looker --address=0.0.0.0 --port=8080
```

## Env vars
| Name | Value | Why |
|------|-------|-----|
| `LOOKER_BASE_URL` | `https://your-instance.cloud.looker.com` | Where to send Looker API calls |
| `LOOKER_USE_CLIENT_OAUTH` | `X-Looker-Token` | **HEADER NAME** to read per-user tokens from. NOT a boolean. |
| `LOOKER_VERIFY_SSL` | `true` | Verify Looker SSL cert |

## Cloud Run config
- `--no-allow-unauthenticated` — requires Google ID token in `Authorization: Bearer` header
- The Reasoning Engine's service account needs `roles/run.invoker` on this service (cross-project: see scripts/05-deploy-adk-agent.sh)

## Why not custom config?
You can also run the toolbox with a `tools.yaml` config file mounted from a secret/volume. The prebuilt mode is simpler and sufficient for our use case (per-user OAuth + standard Looker tools). If you need custom tools or a different auth header, switch to a custom `tools.yaml`:

```yaml
sources:
  looker-source:
    kind: looker
    base_url: https://your-instance.cloud.looker.com
    use_client_oauth: X-Looker-Token  # this is the value LOOKER_USE_CLIENT_OAUTH=X-Looker-Token maps to
    verify_ssl: true
    timeout: 600s
```
