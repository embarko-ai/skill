---
name: embarko-deploy
description: Deploys an application to Embarko, a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL. Use this whenever the user asks to deploy, redeploy, ship, push, or release an app, or to showcase / feature / list a deployed app on an Embarko showcase collection.
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

## Before the first deploy: app requirements

1. It must read its listening port from the `PORT` environment variable — Embarko assigns this dynamically.
2. It must bind to `0.0.0.0`, not `127.0.0.1`/`localhost`.
3. No Dockerfile should be present — Embarko's build system detects the language/framework automatically and builds the image itself.
4. **A static site must have an `index.html` at the root of the archive.**
   Build detection looks for an entry point; a folder holding only
   `landing.html` or `flowly.html` looks like nothing it can serve and the
   build fails. Rename or copy the page to `index.html` *before* packaging
   rather than discovering this from a failed build.
5. **Deploy the folder that holds the actual app, not the folder above
   it.** The build only ever installs dependencies at the root of what you
   upload. Two shapes break this, and both are rejected up front with the
   folder to use instead:
   - an extra wrapping folder from an extracted zip (`myapp/myapp/...`);
   - a **repo root whose `package.json` has no dependencies of its own and
     delegates** — `"build": "npm --prefix frontend run build"`, a
     `cd frontend && …` script, or a `workspaces` entry. This is the usual
     frontend/backend repo layout. Deploy `frontend` itself.

   **One upload = one app.** A repo containing both a frontend and a
   backend is two deploys under two app names, not one.

The app name is also the live subdomain — deployed apps are served at
`https://<app-name>.embarko.app`. Lowercase letters, numbers and
dashes only. If the person names it in prose ("Testing landing page"),
slugify it yourself (`testing-landing-page`) and tell them what you used —
don't send the prose form and take a `400`.

## Token — optional

Set `DEPLOY_TOKEN` in the environment and the script uses it. With no
token the deploy still works: it produces a live but **temporary** app
(auto-deleted after 24h unless claimed later with a real token).

The script finds a token in `DEPLOY_TOKEN`, or in `~/.embarko/credentials`
if a previous run saved one there. If neither exists, it deploys
anonymously rather than stopping — the person gets a live URL either way.

### Turning a temporary app into a permanent one

An anonymous deploy is real and live, but it is **deleted 24 hours later**
unless it gets claimed. The script prints the expiry — relay it, and don't
end the conversation leaving the app to lapse silently.

Claiming needs a token, and you can get one **without the person opening a
browser at all**. Prefer this route:

1. Ask for their email address.
2. Request the token yourself:
   ```bash
   curl -X POST https://ship.embarko.ai/api/public/deploy-tokens/request \
     -H "Content-Type: application/json" \
     -d '{"email": "<their email>"}'
   ```
   This always returns `202` — the token is emailed, never returned in the
   response. An account and company are created automatically if they
   don't exist yet.
3. Ask them to paste back the token from their inbox. There's no way to
   detect this step; wait for it.
4. **Save it yourself — don't ask them to do it:**
   ```bash
   mkdir -p ~/.embarko && printf '%s\n' "<token>" > ~/.embarko/credentials && chmod 600 ~/.embarko/credentials
   ```
5. Redeploy the **same app name**. That claims the existing app — the
   24-hour expiry is cancelled permanently and the URL doesn't change.

The dashboard route (`https://embarko.ai/login` → Tokens → Create) is the
fallback for someone who would rather click than paste, and the only
option if they can't reach that inbox.

### Never ask twice

Once the credential file exists, every later deploy in that environment
picks it up on its own. Do not ask for an email, a token, or a dashboard
visit again — check `DEPLOY_TOKEN` and `~/.embarko/credentials` first, and
say nothing about tokens if either is present.

Never commit the credential file, never print the token back to the
person, and never invent a token value — a wrong token is a hard `401`,
whereas no token at all is a working anonymous deploy.

## Operating the app after it's deployed

With a deploy token you can also fix a deployed app yourself, without
sending the person to the dashboard. Same token, addressed by app name:

```bash
BASE="https://ship.embarko.ai/api/apps/<app-name>"
AUTH="Authorization: Bearer ${DEPLOY_TOKEN}"

# Which variables are set (keys only — values are never returned)
curl -H "$AUTH" "$BASE/env-vars"

# Update one variable, and make it take effect straight away
curl -X PUT -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"value":"sk_live_...","apply":true}' "$BASE/env-vars/STRIPE_SECRET_KEY"

# Or set several at once (a merge: variables you don't list are left alone)
curl -X PUT -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"vars":[{"key":"A","value":"1"},{"key":"B","value":"2"}],"apply":true}' "$BASE/env-vars"

# Deployment history, newest first — `rollbackTarget: true` marks a valid target
curl -H "$AUTH" "$BASE/deployments"

# Undo the last deploy (or pass {"deploymentId":"..."} for a specific one)
curl -X POST -H "$AUTH" -H "Content-Type: application/json" -d '{}' "$BASE/rollback"
```

Three things to get right:

1. **A write alone does not reach the running app.** Saving a variable
   leaves the running container untouched (`"applied": false`). Pass
   `"apply": true` to make it take effect immediately — that re-pushes the
   running image with the new value, no rebuild and no source upload, so
   it works even for an app that can't boot without the variable. After a
   `DELETE`, or several separate writes, `POST $BASE/env-vars/apply` does
   the same thing once. Reporting "I've set it" without applying or
   redeploying leaves the app exactly as broken as you found it.
2. **Rollback returns `202`, not "done".** Poll the `statusUrl` it gives
   you until `terminal` is `true`, same as a deploy.
3. **You cannot read a variable's value back**, only its key. If you need
   to know a secret's value, ask the person — don't try to recover it from
   logs.

Prefer fixing the code and redeploying. Roll back when the app is down and
the cause isn't obvious yet — it restores service while you investigate.

### Custom domains, analytics, renaming, deleting

Same token and `$BASE` as above:

```bash
# Point a domain at the app — returns the exact DNS record to create
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"domain":"app.example.com"}' "$BASE/domains"

# Once that record exists and has propagated, activate it
curl -X POST -H "$AUTH" "$BASE/domains/app.example.com/verify"

# List / remove
curl -H "$AUTH" "$BASE/domains"
curl -X DELETE -H "$AUTH" "$BASE/domains/app.example.com"

# Traffic + resource usage (range: 24h, 7d, 30d, 90d, all)
curl -H "$AUTH" "$BASE/analytics?range=7d"

# Display name only — the app's slug/URL never changes
curl -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"name":"My App"}' "$BASE"
```

The DNS record itself has to be created by whoever controls that domain's
DNS — hand them the record `POST /domains` returns rather than trying to
create it yourself.

**Deleting is irreversible, with no backup.** Only do it when the person
explicitly asked to delete the app — not as a cleanup step you decided on
your own — and confirm with them what's about to be deleted before
sending this:

```bash
curl -X DELETE -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"confirmAppName":"<app-name>"}' "$BASE"
```

`confirmAppName` must exactly match the app's name — a missing or wrong
value returns `400 confirmation_required` and deletes nothing. That check
guards against acting on a misread instruction; it is not a substitute for
actually confirming with the person first.

**Changing the app's web address** is a different call from the rename
above — that one changes the label, this moves the URL:

```bash
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"newName":"my-better-app"}' "$BASE/slug-change"
```

**Ask the person first, every time.** The old address stops working the
moment the new one is live — no redirect, existing links break, and the
freed name can be claimed by someone else. Do it when they have asked for
a different address, not because a name looks untidy to you.

It returns `202` and takes minutes, because the app needs a fresh
certificate for the new hostname. Poll the `statusUrl` until `terminal`
is `true`; `currentSlug` always says where the app actually is, and a
failure leaves it on the old address untouched. Afterwards deploy with
the new name — the response's `deployWith` gives the exact `X-App-Name`.
If a later call returns `404 app_renamed`, follow its `retryUrl` rather
than redeploying, which would create a second empty app. One change per
app per week (`429 slug_change_cooldown`).

A custom domain is carried over and keeps working, and a Showcase listing
keeps its own URL — worth saying, since both look like they would break.

## Showcasing the app

A deployed app can be listed on a public Embarko showcase page (someone's
**collection**). Do this only when the person asks. It needs a deploy
token — an unclaimed temporary app must be claimed first.

**Ask the person for all of the details below before sending — required
ones marked — don't guess or send placeholders; this call publishes.**
You may draft `tagline`/`whatItDoes` from your knowledge of the app for
them to approve. `name`, `tagline`, `whatItDoes`, `category` and `tags`
are also used for the app's SEO (page title, meta description, keywords),
so write them as real, searchable copy — what the app does and who it's
for, in plain words — not marketing fluff or placeholder text. Omit
optional keys they don't give you. Re-running the `PUT` for the same app
updates the listing.

```bash
curl -X PUT "https://ship.embarko.ai/api/apps/<app-name>/showcase" \
  -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "collectionSlug": "<showcase-page-slug>",          // required — slug of the collection they're submitting to
    "name": "<app-name>",                              // required — name shown on the showcase
    "tagline": "<1-3-liner-description-of-app>",       // required
    "creatorName": "<their-name>",                     // required
    "whatItDoes": "<longer-description>",
    "whyBuilt": "<why-they-built-it>",
    "creatorProfile": "<https-profile-url>",
    "builtWith": "<Claude|Codex|Cursor|Lovable|Replit|Other>",           // exactly one of these
    "category": "<AI Tool|Personal|Business|Productivity|Education|Game|Developer Tool|Other>",  // exactly one of these
    "tags": ["<tag>", "<tag>"],
    "videoUrl": "<https-video-url>",
    "screenshotUrl": "<https-image-url>"
  }'
```

A `2xx` means it's listed — relay any URL in the response. A `4xx` carries
a `code`/`error`; fix the input (wrong slug, missing required field,
value not in the list above) rather than retrying the same request.



## Database support (optional)

Apps that need a database can use SQLite, an embedded in-process engine, rather than requiring a separately hosted one. If your app needs this:

1. Add `better-sqlite3` as a dependency.
2. Point it at the `DATA_DIR` environment variable, which Embarko provides automatically and persists across redeploys:
   ```js
   const Database = require('better-sqlite3');
   const db = new Database(`${process.env.DATA_DIR}/app.db`);
   ```
No separate database provisioning, connection strings, or credentials are required. Note that this is a single-instance embedded database, not a shared/scalable one — it's intended for apps that run as a single instance.

SQLite is the only supported embedded database. PGlite (`@electric-sql/pglite`) was previously supported and is not any more — do not use it, and if you are adapting an existing app that uses it, port it to `better-sqlite3` before deploying.

Keep the whole database under `DATA_DIR`, including the `-wal` and `-shm` files SQLite creates alongside it — those are part of the database, and a database split across `DATA_DIR` and somewhere else will lose data.

## Storage requirements

Do not use `window.storage` — it's an API specific to Claude.ai's Artifacts sandbox and does not exist outside it. The script refuses to upload an app that calls it, and the platform rejects it too (HTTP 422, before any build is attempted) with the offending file(s) named. If an app was generated or previewed inside an Artifacts-style tool and uses this API, replace it with SQLite (`better-sqlite3`, see above), writing to a path under `DATA_DIR` so it persists across redeploys.

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
   `*.embarko.app` yourself if you're able to. **In Claude
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

`https://ship.embarko.ai/capabilities` is the machine-readable contract —
runtime requirements, what persists, which features exist and whether you
can invoke them yourself or have to hand the job to the person. No auth
needed, and it's cached. Read it before designing an app around a feature
rather than assuming the feature is there.

`scripts/troubleshoot.md` for common failure modes and their fixes.
`https://embarko.ai/docs` is the canonical platform reference — the full
API, rollback, env vars, changing an app's address, custom domains, and
the platform's actual constraints. Prefer it over this file for anything
not covered here, and trust the live API's behaviour over either if they
ever disagree.
