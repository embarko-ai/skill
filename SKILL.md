---
name: embarko-deploy
description: Deploys an application to Embarko, a managed hosting environment that builds your app automatically (no Dockerfile required) and makes it reachable at a generated URL. Use this whenever the user asks to deploy, redeploy, ship, push, or release an app, or to showcase / feature / list a deployed app on an Embarko showcase page (public or event).
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

## No script, or no network

- `scripts/deploy.sh` missing: follow https://embarko.ai/docs/quickstart.md,
  which has the same deploy as two commands.
- The script says Embarko can't be reached: your environment is blocking
  it. Read the routes in https://embarko.ai/docs/prerequisites.md and tell
  the person the fix in one line.
