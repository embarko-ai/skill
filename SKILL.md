---
name: embarko-deploy
description: Deploys an application to Embarko, a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL. Use this whenever the user asks to deploy, redeploy, ship, push, or release an app.
---

# Embarko Deploy

Deploys an application to Embarko: a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL.

**Do not skip verification.** A successful API response confirms the deployment was *accepted* — it does not confirm the app is *running*. Always verify before reporting the deployment as complete (Step 4).

## Required configuration

Set this as an environment variable before deploying:

- `DEPLOY_TOKEN` — your company's deploy token

**If `DEPLOY_TOKEN` isn't set and no other stored token is found** (check
for one in `~/.embarko/credentials` too, if that convention is in use),
you have two options — offer both, don't just default to the first:

1. **Deploy anonymously right now, no token needed at all.** Omit the
   `Authorization` header entirely (see Step 3) — this still produces a
   live app, just a temporary one (auto-deleted after 24h unless later
   claimed with a real token). Good default when the person just wants to
   see something running immediately.
2. **Get a token first**, either:
   - Dashboard: *"Go to `https://embarko.ai/login`, sign in, open your
     company's Tokens page, and create one. Then paste it here, or set it
     as `DEPLOY_TOKEN` in your environment."*
   - Or, with no browser at all — you can request one yourself:
     `curl -X POST https://ship.embarko.ai/api/public/deploy-tokens/request -H "Content-Type: application/json" -d '{"email": "<their email>"}'`
     — tell the person to check that inbox for the emailed token, then
     paste it back or set `DEPLOY_TOKEN`.

Wait for them to paste the token or confirm the env var is set before
using option 2 — there's no automatic detection of that step. Once you
have it, this only needs to happen once per machine/session — don't ask
again on a later deploy in the same environment if `DEPLOY_TOKEN` (or the
stored credential) is already present.

**If your own environment can't reach `embarko.ai`/`ship.embarko.ai` at
all** (a connection/DNS-level failure, not an HTTP error response): this
usually means a network-sandboxed agent environment with a fixed
outbound-domain allowlist. Check for that setting and add `embarko.ai`,
`ship.embarko.ai`, and `*.app.embarko.ai` yourself if you're able to; if
you can't change it, tell the person exactly which domains need
allowlisting in their agent platform's settings rather than reporting a
generic deploy failure. See `scripts/troubleshoot.md`'s network-sandbox
row for more detail. Don't confuse this with a real HTTP error response
(4xx/5xx) — that's a normal API error, not a network block.

## Embarko requirements

For an app to deploy and run correctly:

1. It must read its listening port from the `PORT` environment variable — Embarko assigns this dynamically.
2. It must bind to `0.0.0.0`, not `127.0.0.1`/`localhost`.
3. No Dockerfile should be present — Embarko's build system detects the language/framework automatically and builds the image itself.

## Database support (optional)

Apps that need a relational database can use an embedded, in-process database rather than requiring a separately hosted one. If your app needs this:

1. Add `@electric-sql/pglite` as a dependency.
2. Point it at the `DATA_DIR` environment variable, which Embarko provides automatically and persists across redeploys:
   ```js
   const { PGlite } = require('@electric-sql/pglite');
   const db = new PGlite(`${process.env.DATA_DIR}/pglite`);
   ```
No separate database provisioning, connection strings, or credentials are required. Note that this is a single-instance embedded database, not a shared/scalable one — it's intended for apps that run as a single instance.

Embarko automatically detects the `@electric-sql/pglite` dependency at deploy time and allocates more memory to the app than a non-database app gets by default — no configuration needed on your end. If your app still runs out of memory (visible as repeated crash-restarts), it likely has other memory-heavy dependencies beyond the database and may need a higher allocation — mention this if it comes up during a deploy.

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

- **App name**: lowercase letters, numbers, and dashes only. No project needs to exist on the dashboard beforehand — the first deploy of a new name auto-creates its project under your company, keyed off your `DEPLOY_TOKEN`. Infer it from the project's manifest file (e.g. `package.json`'s `name` field) or the project folder name. This name is also the live subdomain, so it's unique **platform-wide**: if the call fails with `code: "app_name_taken"`, someone else already has that exact name — pick a different one rather than retrying the same name.
- **Version**: always pass an explicit, unique version — a git commit SHA, a semantic version tag, or a timestamp. Do not omit this or reuse a non-unique/floating tag; deployment systems that cache or pull images by tag can serve a stale build if the tag isn't unique per deploy.

## Step 3: Call the deploy API

Include `Authorization` only if a `DEPLOY_TOKEN` is set — omit the header
entirely for an anonymous deploy (see "Required configuration" above),
never send an empty/placeholder token:

```bash
curl -X POST "https://ship.embarko.ai/apps" \
  -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
  -H "X-App-Name: <app-name>" \
  -H "X-App-Version: <version>" \
  -F "source=@/tmp/<app-name>.tar.gz"
```

This returns `202` immediately — the build/deploy itself runs in the
background:
```json
{
  "success": true,
  "accepted": true,
  "version": "<version>",
  "url": "<the app's eventual live URL>",
  "statusUrl": "https://ship.embarko.ai/apps/<app-name>/status",
  "logsUrl": "https://ship.embarko.ai/apps/<app-name>/logs"
}
```
An anonymous deploy's response also has an `orphan` object (expiry time
and a plain-language message) — relay it to the person rather than
discarding it.

On a non-2xx status, the response always includes a machine-readable `code` field alongside the human-readable `error` — branch on `code`, not on the wording of `error`, which can change:
```json
{ "error": "App name \"acme-portal\" is already in use by a different company", "code": "app_name_taken" }
```

If the `curl` call itself fails to connect (no HTTP response at all — a
DNS/connection error), see "Required configuration" above's note on
network-sandboxed environments before assuming this is a deploy failure.

See `scripts/troubleshoot.md`'s error code reference for what each `code` means and how to fix it — don't just retry blindly.

## Step 4: Verify the deployment

**Never report success from Step 3's `202` alone** — it only confirms the
upload was accepted. Poll `statusUrl` (same `Authorization` header, if
any) every ~10s until `deploy.status` is no longer `"in_progress"`:

```bash
curl -H "Authorization: Bearer ${DEPLOY_TOKEN}" "<statusUrl>"
```

If `deploy.status` is `"failed"`, fetch `logsUrl` the same way, find the
actual error, and check `scripts/troubleshoot.md` (or
`https://embarko.ai/troubleshoot.md` for the full platform reference) for
that exact error text or symptom — apply the fix, then redeploy (repeat
Step 3 with the same `X-App-Name`).

Once `deploy.status` is `"success"`, confirm the app is actually reachable
before reporting it to the user:

```bash
curl "<the returned url>"
```

Only share the live URL once this returns the app's actual content.

## Reference

See `scripts/troubleshoot.md` for common failure modes and their fixes, or
`https://embarko.ai/troubleshoot.md` / `https://embarko.ai/docs.md` for
the full platform reference (rollback, env vars, custom domains, and the
platform's actual constraints — e.g. only `DATA_DIR` survives a redeploy).