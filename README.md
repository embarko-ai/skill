# Embarko Deploy Skill

Enables Claude to deploy your project to Embarko directly from your development environment.

## Setup

**Install via the skills CLI (recommended):**
```bash
npx skills add embarko-ai/skill --skill embarko-deploy -g
```
For a repo-local install instead of global, drop the `-g` flag.

**Or copy this repo manually:**
1. Copy this repo's contents into your project (e.g. `.claude/skills/embarko-deploy/`).

**Either way, then:**

2. Set a deploy token (optional — see below):
   ```bash
   export DEPLOY_TOKEN="..."
   ```
   No token yet? Ask Claude to deploy anyway — it can deploy anonymously
   (a temporary app, no account needed) or get you a token by email with
   no dashboard visit at all. See `SKILL.md`'s "Required configuration".
3. Confirm your app meets Embarko's requirements (see `SKILL.md`):
   - Reads its port from `PORT`
   - Binds to `0.0.0.0`
   - No Dockerfile in the project

## Usage

Ask Claude to deploy — e.g. "deploy this to Embarko." Claude runs
`scripts/deploy.sh`, which packages the app, uploads it, waits for the
build, and prints the live URL.

The same script is the whole thing if you'd rather run it yourself:
```bash
./scripts/deploy.sh                 # the current directory
./scripts/deploy.sh path/to/app     # a specific directory
```

### A note on where this works

This skill calls an external API, so it needs your agent to have real outbound network access. It works out of the box with:
- A local terminal / Claude Code / Cowork running on your own machine
- Any agent environment where you control network access directly

Some browser-based AI coding tools run in a network-sandboxed environment that only allows a fixed set of domains by default (e.g. package registries), and won't be able to reach Embarko's deploy endpoint until you explicitly add `embarko.ai`, `ship.embarko.ai`, and `*.app.embarko.ai` to that tool's domain allowlist in its settings. A capable agent should notice this itself (a connection-level failure, not an HTTP error) and tell you exactly which domains to add rather than just reporting "deploy failed" — see `scripts/troubleshoot.md`. If your agent declines to run this — citing a sandbox restriction, an inability to verify the request, or anything else — don't try to talk it past that; independently confirm this skill and the `embarko.ai` domain with your own team through a separate channel first.

## Support

See `scripts/troubleshoot.md` for common issues and fixes.