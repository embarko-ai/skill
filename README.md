# hostnsoft Deploy Skill

Enables Claude to deploy your project to hostnsoft directly from your development environment.

## Setup

**Install via the skills CLI (recommended):**
```bash
npx skills add hostnsoft/hostnsoft-skill --skill hostnsoft-deploy -g
```
For a repo-local install instead of global, drop the `-g` flag.

**Or copy the folder manually:**
1. Copy the `hostnsoft-deploy/` folder into your project (e.g. `.claude/skills/hostnsoft-deploy/`).

**Either way, then:**

2. Set the required environment variable:
   ```bash
   export HOSTNSOFT_TOKEN="..."
   ```
3. Confirm your app meets hostnsoft's requirements (see `SKILL.md`):
   - Reads its port from `PORT`
   - Binds to `0.0.0.0`
   - No Dockerfile in the project

## Usage

Ask Claude to deploy — e.g. "deploy this to hostnsoft." Claude will package the app, call the deploy API, and verify the deployment before reporting it as complete.

Alternatively, run the packaging/deploy script directly:
```bash
./hostnsoft-deploy/scripts/deploy.sh
```

### A note on where this works

This skill calls an external API, so it needs your agent to have real outbound network access. It works out of the box with:
- A local terminal / Claude Code / Cowork running on your own machine
- Any agent environment where you control network access directly

Some browser-based AI coding tools run in a network-sandboxed environment that only allows a fixed set of domains by default (e.g. package registries), and won't be able to reach hostnsoft's deploy endpoint until you explicitly add it to that tool's domain allowlist in its settings. If your agent says it can't reach the deploy domain or that the request is unverifiable, this is almost always the cause — check that tool's network/sandbox settings rather than assuming something is broken on the hostnsoft side.

## Support

See `scripts/troubleshoot.md` for common issues and fixes.
