# Embarko Documentation

## [Overview](#overview)

Embarko lets agents deploy apps to a live URL.

Every deploy gets a live URL at `<app-name>.app.embarko.ai`. A deploy
token authenticates as a **company** — no separate company header is
needed, the token itself identifies which company a deploy belongs to.

- **Projects auto-create on first deploy.** No dashboard step is
  required beforehand — the first deploy of a new app name creates its
  project under your token's company automatically.
- App names are unique **platform-wide** (an app name is also the live
  subdomain), not just within your company. If another company already
  used the exact name you're deploying, the request fails with
  `code: "app_name_taken"` — pick a different name rather than retrying.
- **No token? You can still deploy.** Omitting `Authorization` entirely
  deploys anonymously — see [Deploying without a token](#anonymous-deploys).
- **Deploys are asynchronous.** `POST /apps` returns `202` as soon as your
  upload is accepted, before the build finishes — see
  [Checking status & logs](#status-and-logs).

## [Deploy prompt for agents](#deploy-prompt)

Copy prompt for agent · Paste in your agent

```
Deploy this app to Embarko with curl directly (no script/package to
install). Full API/error reference — read before improvising anything
not covered here: https://embarko.ai/docs.md and https://embarko.ai/troubleshoot.md

POST https://ship.embarko.ai/apps — header X-App-Name: <lowercase-name>,
header X-App-Version: <git sha or timestamp>, multipart field
source=<tar.gz of the app root, no node_modules/.git>. Add header
"Authorization: Bearer $DEPLOY_TOKEN" only if a real token is known;
omit it entirely otherwise (deploys anonymously — still live, just
temporary — never invent a token).

Rules, don't skip any:
1. Response is 202 (async, not done yet). Poll its "statusUrl" until
   "deploy.status" is "success" or "failed" before reporting anything —
   on "failed", fetch "logsUrl", match the error against troubleshoot.md,
   fix it, redeploy.
2. No token? Offer both: deploy anonymously now (see "orphan" in the
   response), or get one by emailing POST .../api/public/deploy-tokens/request
   {"email":...} — no dashboard needed. Never let the person lose the app
   silently to its 24h expiry.
3. curl fails to connect at all (DNS/connection error, not an HTTP
   response)? That's a network sandbox blocking unfamiliar domains, not
   a deploy failure — allowlist embarko.ai, ship.embarko.ai, and
   *.app.embarko.ai yourself if you can, otherwise tell the person
   exactly which domains to add.
```

Everything above is plain `curl` — nothing to install, nothing to trust
beyond the commands visible in the prompt itself. A packaged skill exists
too (`npx skills add embarko-ai/skill --skill embarko-deploy -g`, see
[Install the skill](#install-skill)) for repeated local use, but it's
optional convenience, not required — prefer the prompt above whenever an
agent would otherwise need to install or execute a third-party script to
deploy.

## [Install the skill](#install-skill)

For repeated use in your own environment, install the skill instead: it
wraps the same calls in a script with packaging, storage-pattern
pre-checks, and error-code-aware guidance.

```bash
npx skills add embarko-ai/skill --skill embarko-deploy -g
```

For a repo-local install instead of global, drop the `-g` flag.

## [Quick start](#quick-start)

**1. Get a deploy token** — see [Authentication](#authentication) (or skip
this and deploy anonymously — see [Deploying without a token](#anonymous-deploys)).

**2. Package and deploy:**

```bash
tar -czf /tmp/my-app.tar.gz --exclude=node_modules --exclude=.git -C /path/to/app .

curl -X POST "https://ship.embarko.ai/apps" \
  -H "Authorization: Bearer $DEPLOY_TOKEN" \
  -H "X-App-Name: my-app" \
  -H "X-App-Version: $(git rev-parse --short HEAD)" \
  -F "source=@/tmp/my-app.tar.gz"
```

**3. Poll until it's live** — see [Checking status & logs](#status-and-logs).
See [Errors](#errors) for what a failed response looks like.

## [Authentication](#authentication)

Every deploy request is authenticated with a **company deploy token**:

```
Authorization: Bearer <token>
```

### [Getting a token](#getting-a-token)

Two ways:

**From the dashboard:**
1. Go to `https://embarko.ai/login` and sign in (or create an account).
2. Open your company's **Deploy tokens** page (`https://embarko.ai/app/tokens`).
3. Enter a label (e.g. `"CI pipeline"`) and click **Create token** —
   it's shown once and cannot be retrieved again. Tokens are prefixed
   `hns_`.
4. Set it as `DEPLOY_TOKEN` in your environment.

**By email, no browser needed** (useful for an agent with no way to open
a dashboard):
```bash
curl -X POST "https://ship.embarko.ai/api/public/deploy-tokens/request" \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com"}'
```
Always returns the same generic `202` regardless of whether the email has
an account — one is created (with a company named after the email) if
none exists. Check that inbox for a new deploy token per company. Rate
limited (per-email, per-IP, and globally) — see
[`troubleshoot.md`](https://embarko.ai/troubleshoot.md).

Deploy tokens authenticate deploys only — they are **not used to sign in**
to the dashboard itself.

### [Rotating or revoking a token](#rotating-a-token)

From the dashboard's Deploy tokens page: **Rotate** issues a replacement
under the same label — the old token keeps working for **one hour**
afterward, so an in-flight CI run doesn't break. **Revoke** disables a token
immediately; use this if a token has leaked.

### [Storing the token](#storing-the-token)

```bash
export DEPLOY_TOKEN="..."
```

or store it in a local credentials file (e.g. `~/.embarko/credentials`,
`chmod 600`) so it doesn't need to be re-entered.

## [Deploying without a token](#anonymous-deploys)

Omit the `Authorization` header entirely — no account needed. This
creates an **unclaimed ("orphan") project** that:
- Gets a `24h` expiry — after that, the app is torn down automatically.
- Shows a live countdown banner injected into the app's own HTML pages.
- Can be **claimed** any time before expiry by redeploying the exact same
  `X-App-Name` with a valid token (see [Getting a token](#getting-a-token))
  — this cancels the expiry permanently and the project behaves like any
  other project from then on.

A present-but-invalid token is always a hard `401`, never silently
treated as anonymous — only a completely absent header opts into this.

## [Deploy](#deploy)

`POST /apps`

Headers:
- `Authorization: Bearer <token>` — optional; omit entirely for an
  anonymous deploy (see above). A present-but-invalid token is always
  `401`.
- `X-App-Name` — required, lowercase letters/numbers/dashes only.
  Auto-creates its project on first use — see [Overview](#overview) on
  the platform-wide uniqueness rule and `app_name_taken`.
- `X-App-Version` — optional, defaults to a timestamp if omitted. Pass an
  explicit unique value (git SHA, semver tag) — a floating/reused tag can
  serve a stale build.

Body: multipart, field `source`, a `.tar.gz` of the app's source.

Response — `202`, the build/deploy continues in the background:
```json
{
  "success": true,
  "accepted": true,
  "message": "Deployment accepted and is building in the background — this can take a few minutes...",
  "version": "abc1234",
  "image": "my-app:abc1234",
  "memory": "256MB",
  "url": "https://my-app.app.embarko.ai",
  "statusUrl": "https://ship.embarko.ai/apps/my-app/status",
  "logsUrl": "https://ship.embarko.ai/apps/my-app/logs"
}
```

An anonymous deploy's response additionally has an `orphan` object —
`expiresAt`, a plain-language `message`, and repeats `statusUrl`/`logsUrl`
— see [Deploying without a token](#anonymous-deploys).

**Never treat this response as "the app is live."** It only confirms the
upload was accepted — see [Checking status & logs](#status-and-logs) next.

## [Checking status & logs](#status-and-logs)

Same host as `POST /apps` (`ship.embarko.ai`) — no separate credentials
needed. **Auth model**: no token needed at all for a still-unclaimed
anonymous app; a claimed app requires the owning company's token — a
missing/wrong one gets `404` (never confirming the app exists to a caller
who doesn't own it), not `401`.

```bash
# Status — poll after every deploy until deploy.status is no longer "in_progress"
curl "https://ship.embarko.ai/apps/my-app/status" -H "Authorization: Bearer $DEPLOY_TOKEN"
```
```json
{
  "appName": "my-app",
  "deploy": { "status": "success", "appVersion": "abc1234", "startedAt": "...", "finishedAt": "...", "errorDetail": null },
  "health": { "...": "live allocation status" }
}
```

```bash
# Logs — a snapshot of the tail, not a live stream; poll it if you need to watch it happen
curl "https://ship.embarko.ai/apps/my-app/logs" -H "Authorization: Bearer $DEPLOY_TOKEN"
curl "https://ship.embarko.ai/apps/my-app/logs?stream=stderr" -H "Authorization: Bearer $DEPLOY_TOKEN"
```
```json
{ "available": true, "allocId": "...", "stream": "stdout", "logs": "...tail of recent output..." }
```

If `deploy.status` is `"failed"`: read the logs, match the actual error
text against [`troubleshoot.md`](https://embarko.ai/troubleshoot.md), apply
the fix, and redeploy under the same `X-App-Name`.

## [Storage requirements](#storage-requirements)

Do not use `window.storage` — it's an API specific to Claude Artifacts'
sandbox and doesn't exist on Embarko. Apps calling it are rejected at
deploy time (`422`, before any build is attempted):

```json
{
  "error": "Unsupported storage pattern detected",
  "code": "unsupported_storage_pattern",
  "detail": "This app calls window.storage, an API specific to Claude Artifacts' sandbox...",
  "filesDetected": ["src/app.jsx"],
  "docs": "https://embarko.ai/docs.md#storage-requirements"
}
```

Use SQLite (`better-sqlite3`) for simple key-value/document data, or
PGlite (`@electric-sql/pglite`) for relational data needing joins —
either way, write to a path under the `DATA_DIR` environment variable so
data persists across redeploys. See
[`troubleshoot.md`](https://embarko.ai/troubleshoot.md) if you're seeing
data disappear on redeploy even without `window.storage` — writing
outside `DATA_DIR` at all has the same effect.

## [Errors](#errors)

Every non-2xx response includes a machine-readable `code` field alongside
the human-readable `error` — branch on `code`, not on `error`'s wording,
which can change without notice.

| `code` | HTTP status | Meaning |
|---|---|---|
| `unauthorized` | `401` | `DEPLOY_TOKEN` present but invalid/revoked — omit the header entirely for an anonymous deploy instead |
| `invalid_app_name` | `400` | `X-App-Name` missing, or doesn't match `^[a-z0-9-]+$` |
| `app_name_taken` | `409` | This exact app name already belongs to a **different** company — names are unique platform-wide |
| `app_name_check_failed` | `502` | Couldn't verify app-name availability (an internal service was unreachable) — transient, safe to retry |
| `invalid_app_version` | `400` | `X-App-Version` doesn't match `^[a-zA-Z0-9._-]+$` |
| `missing_source_file` | `400` | No `source` file in the multipart upload |
| `unsupported_storage_pattern` | `422` | App calls `window.storage` — see [Storage requirements](#storage-requirements) |
| `deploy_failed` | `500` | The build or deploy step itself failed — a catch-all; read `details` for the actual underlying error |

Example:
```json
{ "error": "App name \"my-app\" is already in use by a different company", "code": "app_name_taken" }
```

For anything beyond `POST /apps` itself (rollback, env vars, custom
domains, memory, the platform's actual constraints), see the full
platform reference at [`https://embarko.ai/docs.md`](https://embarko.ai/docs.md)
and [`https://embarko.ai/troubleshoot.md`](https://embarko.ai/troubleshoot.md).
