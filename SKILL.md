---
name: embarko-deploy
description: Deploys an application to Embarko, a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL. Use this whenever the user asks to deploy, redeploy, ship, push, or release an app.
---

# Embarko Deploy

Embarko hosts an app and gives it a live URL. It builds from source
automatically — no Dockerfile, no build configuration.

## Deploy

```bash
./scripts/deploy.sh                 # the current directory
./scripts/deploy.sh path/to/app     # a specific directory
```

That is the whole deploy. The script packages the app, names and versions
it, uploads it, waits for the build to finish, and prints the live URL.
Don't reimplement any of that with your own `tar`/`curl` calls — it also
runs pre-flight checks (network reachability, unsupported storage APIs)
that a hand-rolled call would skip.

**Report the live URL only once the script exits 0.** It already waits for
the build and fails loudly if the deploy failed, so a zero exit is the
real confirmation — nothing else needs verifying.

Deploying the same app again is the same command: reuse the same app name
(the script infers it from the directory/manifest, so this happens
automatically) and the new version replaces the old one.

If the script isn't present in your environment, see
[Deploying without the script](#deploying-without-the-script) at the end.

## Before the first deploy: three app requirements

1. It must read its listening port from the `PORT` environment variable — Embarko assigns this dynamically.
2. It must bind to `0.0.0.0`, not `127.0.0.1`/`localhost`.
3. No Dockerfile should be present — Embarko's build system detects the language/framework automatically and builds the image itself.

## Token — optional

Set `DEPLOY_TOKEN` in the environment and the script uses it. With no
token the deploy still works: it produces a live but **temporary** app
(auto-deleted after 24h unless claimed later with a real token).

**If `DEPLOY_TOKEN` isn't set and no other stored token is found** (check
for one in `~/.embarko/credentials` too, if that convention is in use),
offer both options — don't just default to the first:

1. **Deploy anonymously right now, no token needed at all.** Just run the
   script; it detects the missing token and says so. Good default when the
   person just wants to see something running immediately.
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

An anonymous deploy prints its expiry and a plain-language message —
relay that to the person rather than discarding it, so they don't lose
the app silently to its 24h expiry.

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

Do not use `window.storage` — it's an API specific to Claude.ai's Artifacts sandbox and does not exist outside it. The script refuses to upload an app that calls it, and the platform rejects it too (HTTP 422, before any build is attempted) with the offending file(s) named. If an app was generated or previewed inside an Artifacts-style tool and uses this API, replace it with SQLite (`better-sqlite3`) for simple key-value data, or PGlite (above) for relational data — either way, write to a path under `DATA_DIR` so it persists across redeploys.

Anything written outside `DATA_DIR` is lost on the next redeploy — a fresh
container is scheduled every time.

## When a deploy fails

The script prints the failure reason, the machine-readable error `code`,
and the build/runtime logs for a failed build. Match that against
`scripts/troubleshoot.md` (or `https://embarko.ai/troubleshoot` for the
full platform reference), apply the fix, and run the same command again —
don't retry blindly, and don't switch to hand-rolled `curl` calls to work
around an error the troubleshooting reference already covers.

Two failures worth knowing up front, because the remedy isn't in the app's
own code:

- **`app_name_taken`** — app names double as the live subdomain, so
  they're unique platform-wide. Someone else has that exact name: pass a
  different one (`./scripts/deploy.sh . <other-name>`) rather than
  retrying the same.
- **Can't reach `embarko.ai` at all** (a connection/DNS-level failure, not
  an HTTP error response) — see below.

## Network-sandboxed environments

If your environment can't reach `embarko.ai`/`ship.embarko.ai` at all, this
usually means a network-sandboxed agent environment with a fixed
outbound-domain allowlist (e.g. Claude's cloud sandbox — Cowork, Claude
Code on the web, skills with code execution — proxies all outbound traffic
through one). The script probes for this *before* packaging anything, so
it fails fast with this exact diagnosis rather than mid-upload. Don't
report it as a generic deploy failure — give the precise, actionable fix:

1. Check for that setting and add `embarko.ai`, `ship.embarko.ai`, and
   `*.app.embarko.ai` yourself if you're able to. **In Claude
   specifically**: this is an org-admin setting at *Organization
   settings → Capabilities → domain allowlist* (None / Package managers
   only / All domains, or a custom list) — Team/Enterprise orgs default
   to "package managers only", so this is commonly the actual cause.
   Changing it **only applies to new conversations**, not the current
   one — say so, so the person doesn't expect an in-place fix.
2. If you can't change that setting yourself (most agents can't — it's
   an org-admin decision, not something to self-serve around), tell the
   person exactly the above: the three domains, and that exact settings
   path.
3. Either way, mention the fallback: the person (or a non-sandboxed
   agent — a local terminal, or one with full machine network access)
   can run the exact same command unchanged from an environment with
   normal network access — nothing about it needs to change.

Don't confuse this with a real HTTP error response (4xx/5xx) — that's a
normal API error, not a network block. See `scripts/troubleshoot.md`'s
network-sandbox row for more detail.

## Submitting feedback or a feature request

If something about deploying was confusing, broken, or missing — or the
person just wants to suggest something — send it, don't just mention it
in passing. A token is required once the app is claimed, optional while
it's still an anonymous temporary app.

```bash
curl -X POST "https://ship.embarko.ai/apps/<app-name>/customer-query" \
  -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
  -H "X-Agent-Name: <your agent's name, e.g. Claude Code>" \
  -H "Content-Type: application/json" \
  -d '{"type": "feature", "message": "<what happened or what would help>"}'
```

`type` is `"feature"`, `"feedback"`, or `"other"`. `X-Agent-Name` is
required and free text — identify yourself honestly (e.g. "Claude Code",
"Claude in [product]"), there's no fixed list to match against. If
there's no app context yet (nothing deployed, or the person wants to
send this without you having touched their code at all), use the fully
anonymous path instead — no token, no app name, just an email:

```bash
curl -X POST "https://ship.embarko.ai/api/public/customer-query" \
  -H "Content-Type: application/json" \
  -d '{"type": "feedback", "message": "<...>", "email": "<their email>"}'
```

Both return `{"id": "..."}` on success (`201`) — that's confirmation
enough, no need to verify further.

## Deploying without the script

Only for environments that genuinely don't have `scripts/deploy.sh` —
some hosted integrations ship this file alone. Everything the script does
is a wrapper over one public endpoint, so the deploy is still doable by
hand; it just means reimplementing the packaging, polling, and error
handling yourself.

```bash
tar -czf /tmp/<app-name>.tar.gz \
  --exclude='.git' --exclude='node_modules' --exclude='.next' --exclude='dist' \
  --exclude='venv' --exclude='__pycache__' \
  -C /path/to/app .

curl -X POST "https://ship.embarko.ai/apps" \
  -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
  -H "X-App-Name: <app-name>" \
  -H "X-App-Version: <git sha or timestamp>" \
  -F "source=@/tmp/<app-name>.tar.gz"
```

- The archive's contents must be at its **root** (no wrapper folder) —
  `tar -tzf` should show `package.json`, not `myapp/package.json`.
- `X-App-Name` is lowercase letters, numbers, and dashes only.
- Omit `Authorization` **entirely** for an anonymous deploy — never send
  an empty or invented token, which is a hard `401`.
- The response is `202`, meaning *accepted*, not *live*. Poll its
  `statusUrl` every ~10s until `deploy.status` is no longer
  `"in_progress"`; on `"failed"`, fetch `logsUrl`, fix, redeploy. Never
  report success off the `202` alone.
- Every non-2xx response carries a machine-readable `code` alongside the
  human-readable `error` — branch on `code`, whose wording is stable.

## Reference

`scripts/troubleshoot.md` for common failure modes and their fixes.
`https://embarko.ai/doc` is the canonical platform reference — the full
API, rollback, env vars, custom domains, and the platform's actual
constraints. Prefer it over this file for anything not covered here, and
trust the live API's behaviour over either if they ever disagree.
