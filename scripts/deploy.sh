#!/usr/bin/env bash
# Package an app directory and deploy it to Embarko.
#
# Usage:
#   ./deploy.sh [path-to-app-dir] [app-name] [version]
#
# All args are optional:
#   - app-dir defaults to the current directory
#   - app-name defaults to the "name" field in package.json (sanitized), or the folder name
#     — no project needs to exist beforehand, the first deploy of a new
#     name auto-creates it; the name is unique platform-wide though (it's
#     also the live subdomain), so a name already taken by another company
#     fails with code "app_name_taken" — see scripts/troubleshoot.md
#   - version defaults to the current git short SHA if in a git repo, else a timestamp
#
# Always pass a unique version — never reuse a floating tag such as "latest".
#
# Optional environment variable:
#   DEPLOY_TOKEN   — your company deploy token. If unset, this deploys
#                    ANONYMOUSLY: a live but temporary app (auto-deleted
#                    after 24h unless later claimed with a real token —
#                    see SKILL.md for how to get one, including by email
#                    with no dashboard visit at all).

set -euo pipefail

APP_DIR="${1:-.}"
DEPLOY_URL="https://ship.embarko.ai/apps"

# Fail-fast connectivity probe, BEFORE packaging anything. A network-
# sandboxed agent environment (a fixed outbound-domain allowlist — common
# for browser/cloud-based AI coding tools, e.g. Claude's cloud sandbox)
# fails at the CONNECTION level here, distinct from a real HTTP response
# (even a 404/405 from this GET means the network path itself is fine —
# this endpoint only accepts POST, so a non-2xx status is expected and
# irrelevant; only a curl-level connection failure matters). Checking
# this deterministically, before any packaging/upload work, means every
# agent gives the same precise remedy instead of guessing after a
# confusing failure mid-deploy.
if ! curl -sS --connect-timeout 5 -o /dev/null "$DEPLOY_URL" 2>/tmp/embarko-probe-error; then
  echo "==> ERROR: cannot reach ship.embarko.ai at all (connection/DNS failure, not an HTTP error)." >&2
  echo "    This is almost always a network-sandboxed agent environment with a fixed" >&2
  echo "    outbound-domain allowlist, not a real Embarko problem." >&2
  echo "" >&2
  echo "    Fix — pick one:" >&2
  echo "    1. If you can change your agent platform's network settings, allow these" >&2
  echo "       three domains: embarko.ai, ship.embarko.ai, *.app.embarko.ai" >&2
  echo "       (In Claude specifically: Organization settings -> Capabilities ->" >&2
  echo "       domain allowlist -> add them, or switch to \"All domains\". This is an" >&2
  echo "       org-admin setting, and it only applies to NEW conversations/sessions —" >&2
  echo "       start a fresh one after changing it.)" >&2
  echo "    2. If you can't change that setting yourself, tell the person running you" >&2
  echo "       exactly the above — the three domains and that exact settings path —" >&2
  echo "       instead of reporting a generic deploy failure." >&2
  echo "    3. Or ask them to run this exact script from an environment with normal" >&2
  echo "       network access instead (their own machine, or any agent that isn't" >&2
  echo "       sandboxed) — nothing else needs to change." >&2
  rm -f /tmp/embarko-probe-error
  exit 1
fi
rm -f /tmp/embarko-probe-error

# Infer app name if not passed explicitly
if [[ -n "${2:-}" ]]; then
  APP_NAME="$2"
elif [[ -f "$APP_DIR/package.json" ]]; then
  APP_NAME=$(node -p "require('$APP_DIR/package.json').name" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
else
  APP_NAME=$(basename "$(cd "$APP_DIR" && pwd)" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
fi

if [[ ! "$APP_NAME" =~ ^[a-z0-9-]+$ ]]; then
  echo "ERROR: could not determine a valid app name (got '$APP_NAME')." >&2
  echo "Pass one explicitly: ./deploy.sh <app-dir> <app-name> [version]" >&2
  exit 1
fi

# Infer version if not passed explicitly
if [[ -n "${3:-}" ]]; then
  VERSION="$3"
elif git -C "$APP_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  VERSION=$(git -C "$APP_DIR" rev-parse --short HEAD)
else
  VERSION=$(date +%Y%m%d-%H%M%S)
fi

TARBALL="/tmp/${APP_NAME}.tar.gz"

# Fail fast locally if the app uses window.storage — Embarko's deploy
# API rejects this at build time anyway, but catching it here saves a
# packaging + upload round trip.
if grep -rlF --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' \
    --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build \
    -- 'window.storage' "$APP_DIR" >/tmp/embarko-storage-check 2>/dev/null; then
  echo "ERROR: found window.storage usage (not supported on Embarko) in:" >&2
  cat /tmp/embarko-storage-check >&2
  echo "See SKILL.md's Storage requirements section for the fix (SQLite or PGlite)." >&2
  rm -f /tmp/embarko-storage-check
  exit 1
fi
rm -f /tmp/embarko-storage-check

echo "==> App: ${APP_NAME}  Version: ${VERSION}"
echo "==> Packaging ${APP_DIR} -> ${TARBALL}"
tar -czf "$TARBALL" \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='.next' \
  --exclude='dist' \
  --exclude='venv' \
  --exclude='__pycache__' \
  -C "$APP_DIR" .

# Built as an array, not a string — an empty DEPLOY_TOKEN must OMIT the
# Authorization header entirely (anonymous deploy), not send an empty
# Bearer value, which the API would reject as an invalid token (401)
# rather than treating it as anonymous.
CURL_AUTH_ARGS=()
if [[ -n "${DEPLOY_TOKEN:-}" ]]; then
  CURL_AUTH_ARGS=(-H "Authorization: Bearer ${DEPLOY_TOKEN}")
else
  echo "==> No DEPLOY_TOKEN set — deploying anonymously (temporary app, see SKILL.md)."
fi

echo "==> Deploying to ${DEPLOY_URL}"
RESPONSE=$(curl -sS -X POST "$DEPLOY_URL" \
  "${CURL_AUTH_ARGS[@]}" \
  -H "X-App-Name: ${APP_NAME}" \
  -H "X-App-Version: ${VERSION}" \
  -F "source=@${TARBALL}")

echo "==> Response:"
echo "$RESPONSE"
rm -f "$TARBALL"

if ! echo "$RESPONSE" | grep -q '"success":true'; then
  # Every error response carries a machine-readable `code` field — surface
  # it distinctly so it isn't buried in the raw JSON above. See
  # scripts/troubleshoot.md's error code reference for what each means.
  CODE=$(echo "$RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0)).code' 2>/dev/null || true)
  if [[ -n "$CODE" && "$CODE" != "undefined" ]]; then
    echo "==> Deploy failed (code: ${CODE}) — see scripts/troubleshoot.md before retrying."
  else
    echo "==> Deploy failed — inspect the response above before retrying."
  fi
  exit 1
fi

ORPHAN_MESSAGE=$(echo "$RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0)).orphan?.message' 2>/dev/null || true)
if [[ -n "$ORPHAN_MESSAGE" && "$ORPHAN_MESSAGE" != "undefined" ]]; then
  echo ""
  echo "==> This is a TEMPORARY (anonymous) deploy:"
  echo "$ORPHAN_MESSAGE"
fi

# Deploy is accepted (202) at this point, not yet live — the build/deploy
# itself runs in the background. Poll statusUrl until it's no longer
# in_progress rather than reporting success off the 202 alone.
STATUS_URL=$(echo "$RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0)).statusUrl' 2>/dev/null || true)
LOGS_URL=$(echo "$RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0)).logsUrl' 2>/dev/null || true)

if [[ -z "$STATUS_URL" || "$STATUS_URL" == "undefined" ]]; then
  echo ""
  echo "==> Deploy accepted, but no statusUrl in the response — verify the app is actually running before considering this complete."
  exit 0
fi

echo ""
echo "==> Deploy accepted — polling ${STATUS_URL} for build/deploy progress..."
for _ in $(seq 1 60); do
  STATUS_RESPONSE=$(curl -sS "${CURL_AUTH_ARGS[@]}" "$STATUS_URL")
  DEPLOY_STATUS=$(echo "$STATUS_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0)).deploy.status' 2>/dev/null || echo "unknown")
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    echo "==> Deploy succeeded."
    exit 0
  elif [[ "$DEPLOY_STATUS" == "failed" ]]; then
    echo "==> Deploy failed. Logs (${LOGS_URL}):"
    curl -sS "${CURL_AUTH_ARGS[@]}" "$LOGS_URL"
    echo ""
    echo "==> See scripts/troubleshoot.md (or https://embarko.ai/troubleshoot) for this error, then redeploy."
    exit 1
  fi
  sleep 10
done

echo "==> Still in progress after 10 minutes of polling — check ${STATUS_URL} manually before assuming something is wrong."
exit 1