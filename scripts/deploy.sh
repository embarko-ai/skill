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
# Required environment variable:
#   DEPLOY_TOKEN   — your company deploy token (see SKILL.md if you don't have one yet)

set -euo pipefail

APP_DIR="${1:-.}"
DEPLOY_URL="https://ship.hostnsoft.com/apps"

: "${DEPLOY_TOKEN:?Set DEPLOY_TOKEN in your environment before running this script}"

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

echo "==> Deploying to ${DEPLOY_URL}"
RESPONSE=$(curl -sS -X POST "$DEPLOY_URL" \
  -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
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

if echo "$RESPONSE" | grep -q '"warnings":\[{' ; then
  echo "==> Deploy succeeded but returned warnings — review them before considering this fully done:"
  echo "$RESPONSE"
fi

echo ""
echo "==> Deploy accepted. Verify the app is actually running before considering this complete."