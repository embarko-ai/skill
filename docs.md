# Embarko Documentation

## [Overview](#overview)

Embarko lets agents deploy apps to a live URL.

Every deploy gets a live URL at `<app-name>.app.hostnsoft.com`. A deploy
token authenticates as a **company** — no separate company header is
needed, the token itself identifies which company a deploy belongs to.

- **Projects auto-create on first deploy.** No dashboard step is
  required beforehand — the first deploy of a new app name creates its
  project under your token's company automatically.
- App names are unique **platform-wide** (an app name is also the live
  subdomain), not just within your company. If another company already
  used the exact name you're deploying, the request fails with
  `code: "app_name_taken"` — pick a different name rather than retrying.
- No anonymous/no-account mode — a deploy token is required for every
  request.

## [Install the skill](#install-skill)

Copy prompt for agent · Paste in your agent

```
Deploy this to Embarko: POST https://ship.hostnsoft.com/apps with
header Authorization: Bearer $DEPLOY_TOKEN, header X-App-Name: <name>,
and multipart field source=<tarball of the app>. Full docs:
https://hostnsoft.com/docs. (A helper skill exists too —
npx skills add embarko-ai/skill --skill embarko-deploy -g — but that's
optional convenience, not required; the curl call above works standalone.)
```

The plain HTTP call above works without installing anything, and is what
the copy prompt leads with — no install step required to get started.

For repeated use, install the skill instead: it wraps the same call in a
script with packaging, storage-pattern pre-checks, and error-code-aware
guidance, so you don't have to re-derive any of the above by hand each
time.

```
npx skills add embarko-ai/skill --skill embarko-deploy -g
```

For a repo-local install instead of global, drop the `-g` flag. This is
the preferred way to work with Embarko repeatedly — reach for the raw
`curl` above only for a one-off call or when you can't install anything.

## [Quick start](#quick-start)

Deploy an app in two steps.

**1. Get a deploy token** — see [Authentication](#authentication).

**2. Package and deploy:**

```bash
tar -czf /tmp/my-app.tar.gz --exclude=node_modules --exclude=.git -C /path/to/app .

curl -X POST "https://ship.hostnsoft.com/apps" \
  -H "Authorization: Bearer $DEPLOY_TOKEN" \
  -H "X-App-Name: my-app" \
  -H "X-App-Version: $(git rev-parse --short HEAD)" \
  -F "source=@/tmp/my-app.tar.gz"
```

Check the response for `"success": true` and a live `url`. See
[Deploy](#deploy) for the full response shape, and [Errors](#errors) for
what a failed response looks like. If you've installed the skill (see
above), prefer running it over hand-rolling this `curl` call — it packages
the tarball, runs the storage-pattern pre-check locally, and surfaces the
error `code` for you.

## [Authentication](#authentication)

Every deploy request is authenticated with a **company deploy token**:

```
Authorization: Bearer <token>
```

### [Getting a token](#getting-a-token)

Deploy tokens are created from the dashboard — there is currently no
API-driven or agent-assisted way to mint one:

1. Go to `https://hostnsoft.com/login` and sign in (or create an account).
2. Open your company's **Deploy tokens** page
   (`https://hostnsoft.com/app/tokens`).
3. Enter a label (e.g. `"CI pipeline"`) and click **Create token** —
   it's shown once and cannot be retrieved again. Tokens are prefixed
   `hns_`.
4. Set it as `DEPLOY_TOKEN` in your environment.

Deploy tokens authenticate deploys only — per the dashboard's own note,
they are **not used to sign in** to the dashboard itself.

### [Rotating or revoking a token](#rotating-a-token)

From the same page: **Rotate** issues a replacement under the same
label — the old token keeps working for **one hour** afterward, so an
in-flight CI run doesn't break. **Revoke** disables a token immediately;
use this if a token has leaked.

### [Storing the token](#storing-the-token)

```bash
export DEPLOY_TOKEN="..."
```

or store it in a local credentials file (e.g. `~/.embarko/credentials`,
`chmod 600`) so it doesn't need to be re-entered.

## [Deploy](#deploy)

`POST /apps`

Headers:
- `Authorization: Bearer <token>` — required. Identifies both the caller
  and its company; there is no separate company header.
- `X-App-Name` — required, lowercase letters/numbers/dashes only.
  Auto-creates its project on first use — see [Overview](#overview) on
  the platform-wide uniqueness rule and `app_name_taken`.
- `X-App-Version` — optional, defaults to a timestamp if omitted. Pass an
  explicit unique value (git SHA, semver tag) — a floating/reused tag can
  serve a stale build.

Body: multipart, field `source`, a `.tar.gz` of the app's source.

Response (success):
```json
{
  "success": true,
  "message": "Deployment successful!",
  "version": "abc1234",
  "image": "my-app:abc1234",
  "memory": "256MB",
  "url": "https://my-app.app.hostnsoft.com"
}
```

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
  "docs": "https://hostnsoft.com/docs#storage-requirements"
}
```

Use SQLite (`better-sqlite3`) for simple key-value/document data, or
PGlite (`@electric-sql/pglite`) for relational data needing joins —
either way, write to a path under the `DATA_DIR` environment variable so
data persists across redeploys.

## [Errors](#errors)

Every non-2xx response includes a machine-readable `code` field alongside
the human-readable `error` — branch on `code`, not on `error`'s wording,
which can change without notice.

| `code` | HTTP status | Meaning |
|---|---|---|
| `unauthorized` | `401` | `DEPLOY_TOKEN` missing, invalid, or revoked |
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
