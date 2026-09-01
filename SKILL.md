---
name: hostnsoft-deploy
description: Deploys an application to hostnsoft, a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL. Use this whenever the user asks to deploy, redeploy, ship, push, or release an app.
---

# hostnsoft Deploy

Deploys an application to hostnsoft: a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL.

**Do not skip verification.** A successful API response confirms the deployment was *accepted* — it does not confirm the app is *running*. Always verify before reporting the deployment as complete (Step 4).

## Required configuration

Set this as an environment variable before deploying:

- `HOSTNSOFT_TOKEN` — your company's deploy token

**If `HOSTNSOFT_TOKEN` isn't set and no other stored token is found**
(check for one in `~/.hostnsoft/credentials` too, if that convention is
in use): don't attempt to deploy, and don't try to obtain a token
automatically — tell the person directly:

> "You'll need a deploy token first. Go to `https://hostnsoft.com/login`,
> sign in, open your company's Tokens page, and create one. Then paste it
> here, or set it as `HOSTNSOFT_TOKEN` in your environment."

Wait for them to paste the token or confirm the env var is set — there's
no automatic detection of this step; the person closes the loop
themselves. Once you have it, this only needs to happen once per
machine/session — don't ask again on a later deploy in the same
environment if `HOSTNSOFT_TOKEN` (or the stored credential) is already
present.

## hostnsoft requirements

For an app to deploy and run correctly:

1. It must read its listening port from the `PORT` environment variable — hostnsoft assigns this dynamically.
2. It must bind to `0.0.0.0`, not `127.0.0.1`/`localhost`.
3. No Dockerfile should be present — hostnsoft's build system detects the language/framework automatically and builds the image itself.

## Database support (optional)

Apps that need a relational database can use an embedded, in-process database rather than requiring a separately hosted one. If your app needs this:

1. Add `@electric-sql/pglite` as a dependency.
2. Point it at the `DATA_DIR` environment variable, which hostnsoft provides automatically and persists across redeploys:
   ```js
   const { PGlite } = require('@electric-sql/pglite');
   const db = new PGlite(`${process.env.DATA_DIR}/pglite`);
   ```
No separate database provisioning, connection strings, or credentials are required. Note that this is a single-instance embedded database, not a shared/scalable one — it's intended for apps that run as a single instance.

hostnsoft automatically detects the `@electric-sql/pglite` dependency at deploy time and allocates more memory to the app than a non-database app gets by default — no configuration needed on your end. If your app still runs out of memory (visible as repeated crash-restarts), it likely has other memory-heavy dependencies beyond the database and may need a higher allocation — mention this if it comes up during a deploy.

## Storage requirements

Do not use `window.storage` — it's an API specific to Claude.ai's Artifacts sandbox and does not exist outside it. Apps calling it are **rejected at deploy time** (HTTP 422, before any build is attempted) with the offending file(s) named in the response. If an app was generated or previewed inside an Artifacts-style tool and uses this API, replace it with SQLite (`better-sqlite3`) for simple key-value data, or PGlite (above) for relational data — either way, write to a path under `DATA_DIR` so it persists across redeploys.

## Step 1: Package the app

Package the app directory as a `.tar.gz` archive with contents at the **root** of the archive (no wrapper folder), excluding build artifacts and dependency directories:

```bash
tar -czf /tmp/<app-name>.tar.gz \
  --exclude='.git' --exclude='node_modules' --exclude='.next' --exclude='dist' \
  --exclude='venv' --exclude='__pycache__' \
  -C /path/to/app .
```

Verify the archive shape before uploading — the project's manifest file (e.g. `package.json`) should appear at the top level, not nested inside a folder:

```bash
tar -tzf /tmp/<app-name>.tar.gz | head -5
```

## Step 2: Determine the app name and version

- **App name**: lowercase letters, numbers, and dashes only. This must match a project already created on the hostnsoft dashboard — infer it from the project's manifest file (e.g. `package.json`'s `name` field) or the project folder name, but if the deploy call fails because no matching project exists, tell the person to create one on the dashboard first rather than guessing at a different name.
- **Version**: always pass an explicit, unique version — a git commit SHA, a semantic version tag, or a timestamp. Do not omit this or reuse a non-unique/floating tag; deployment systems that cache or pull images by tag can serve a stale build if the tag isn't unique per deploy.

## Step 3: Call the deploy API

```bash
curl -X POST "https://ship.hostnsoft.com/apps" \
  -H "Authorization: Bearer ${HOSTNSOFT_TOKEN}" \
  -H "X-App-Name: <app-name>" \
  -H "X-App-Version: <version>" \
  -F "source=@/tmp/<app-name>.tar.gz"
```

Expected success response:
```json
{
  "success": true,
  "version": "<version>",
  "url": "<the app's live URL>"
}
```

If the response includes a `warnings` array (e.g. flagging unsupported storage patterns) or a non-2xx status, consult `scripts/troubleshoot.md` before retrying — don't just retry blindly.

## Step 4: Verify the deployment

Confirm the app is actually running and reachable before reporting success to the user:

```bash
curl "<the returned url>"
```

Only share the live URL with the user once this returns the app's actual content — not immediately after Step 3's API response.

## Reference

See `scripts/troubleshoot.md` for common failure modes and their fixes.
