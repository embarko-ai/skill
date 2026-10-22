---
name: embarko-deploy
description: Deploys an application to Embarko, a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL. Use this whenever the user asks to deploy, redeploy, ship, push, or release an app, to make a deployed app do something on a timer (daily report, nightly clean-up), or to showcase / feature / list a deployed app on an Embarko showcase page (public or event).
---

# Embarko Deploy

Embarko hosts an app and gives it a live URL at `<app-name>.embarko.app`.
It builds from source automatically: no Dockerfile, no build configuration.

This skill adds one thing: `scripts/deploy.sh`, which does the whole deploy
for you. Everything else (how to talk to the person, what an app needs,
keeping it, managing it, Showcase, errors) is in the Embarko agent guide,
and the guide is the only copy. Open the one topic you need when you need
it:

| You need | Read |
| --- | --- |
| How to reply to the person, which route to use, whether the app fits | https://embarko.ai/docs/prerequisites.md |
| The whole flow, step by step | https://embarko.ai/docs/quickstart.md |
| What an app needs to run (PORT, 0.0.0.0, DATA_DIR, no Dockerfile) | https://embarko.ai/docs/deploy.md |
| An error code | https://embarko.ai/docs/errors.md |
| Keeping a temporary app | https://embarko.ai/docs/claim.md |
| Running something on a timer | https://embarko.ai/docs/schedules.md |
| The embarko.json file | https://embarko.ai/docs/embarko-json.md |
| Making the app private (optional) (only the team can open it) | https://embarko.ai/docs/lock.md |
| Secrets, domains, logs, rollback, rename, delete | https://embarko.ai/docs/index.md (contents) |
| Showcase | https://embarko.ai/docs/showcase.md |
| Reporting a problem | https://embarko.ai/docs/feedback.md |

Every Embarko reply also carries `next` (the one thing to do now) and, when
there is more to know, `links.help` (the guide topic to read). Follow them.

## Deploy

```bash
./scripts/deploy.sh                 # the current directory
./scripts/deploy.sh path/to/app     # a specific directory
./scripts/deploy.sh . other-name    # a different app name
```

The script packages the app, names and versions it, uploads it, waits for
the build, and prints the live URL. It also checks first that Embarko is
reachable and that the app doesn't use unsupported storage. Don't replace
it with your own `tar`/`curl` calls.

- **Report the live URL only once the script exits 0.** A zero exit means
  the app is live.
- **Then do what it prints under `==> Next:`.** After a first deploy
  without a token that is keeping the app; on a failure, how to fix it.
- **`==> Keep it:`** is the claim link for a temporary app. Give it to the
  person: opening it and signing in keeps the app. It is printed once only.
- Deploying again is the same command; the script reuses the app name.

Optional settings:

| Variable | What it is |
| --- | --- |
| `EMBARKO_AGENT_NAME` | Your agent name in lowercase (`claude-code`, `claude`, `cursor`...). Filled in automatically inside Claude Code. |
| `EMBARKO_APP_TYPE` | A short label for what the app is (`portfolio`, `task management`...). Use it if you know; otherwise leave it out. |
| `DEPLOY_TOKEN` | The person's deploy token. Without one, the first deploy is temporary (24 hours) until kept. |

The script finds a token in `DEPLOY_TOKEN`, then in `~/.embarko/credentials`.
Once one is saved there, never ask the person for it again, and never print
it back.

## Run something on a timer

When the person wants something done at set times ("every Monday at 9",
"each night"), use schedules, not a cron library or crontab. Needs a
deploy token.

1. Put the job in a GET route, e.g. `/tasks/weekly-report`. Answer 2xx when
   it worked. Keep anything it must remember under `DATA_DIR`.
2. First line of that route: answer 401 unless `Authorization` is
   `Bearer ` + `process.env.CRON_SECRET`. Embarko creates that variable.
3. Add `embarko.json` to the app's top folder, in the person's time zone:

   ```json
   {
     "$schema": "https://embarko.ai/schema/embarko.json",
     "schedules": [
       { "cron": "0 9 * * 1", "path": "/tasks/weekly-report", "timezone": "Asia/Kolkata" }
     ]
   }
   ```

4. Deploy as usual. Once live, the script runs each schedule once and
   prints `ok` or the error. Fix and redeploy until every line says `ok`.

The file is the app's full list: edit it and redeploy to change times,
`"schedules": []` removes all. Never put secrets in it; use env vars. If
the script prints warnings, fix them before telling the person it's done.
Details: https://embarko.ai/docs/schedules.md and
https://embarko.ai/docs/embarko-json.md

## No script, or no network

- `scripts/deploy.sh` missing: follow https://embarko.ai/docs/quickstart.md,
  which has the same deploy as two commands.
- The script says Embarko can't be reached: your environment is blocking
  it. Read the routes in https://embarko.ai/docs/prerequisites.md and tell
  the person the fix in one line.
