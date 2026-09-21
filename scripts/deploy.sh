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
#     fails with code "app_name_taken" — see https://embarko.ai/troubleshoot
#   - version defaults to the current git short SHA if in a git repo, else a timestamp
#
# Always pass a unique version — never reuse a floating tag such as "latest".
#
# Optional environment variables:
#   DEPLOY_TOKEN   — your company deploy token. If unset, this deploys
#                    ANONYMOUSLY: a live but temporary app (auto-deleted
#                    after 24h unless later claimed with a real token —
#                    see https://embarko.ai/docs for how to get one,
#                    including by email with no dashboard visit at all).
#   EMBARKO_LP_VARIANT
#                  — landing-page attribution only: which marketing page
#                    produced this deploy. Sent as the `lp_variant` header,
#                    which the deploy prompt on embarko.ai used to carry
#                    inline back when that prompt was raw curl. Purely
#                    informational — never required, and absent for every
#                    deploy that didn't start from a landing page.

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
  echo "Use SQLite (better-sqlite3) instead, writing under DATA_DIR." >&2
  echo "Details: https://embarko.ai/docs" >&2
  rm -f /tmp/embarko-storage-check
  exit 1
fi
rm -f /tmp/embarko-storage-check

# Fail fast on a static site with no entry point. Build detection needs an
# index.html at the archive root; a folder holding only landing.html (or a
# single generated page under some other name) builds into nothing servable
# and fails several minutes later, at the build step, with a message that
# doesn't name the real cause. Only applies when there is no other buildable
# manifest — a Node/Python/Go app is detected by its manifest, not by HTML.
EMBARKO_MANIFESTS=(package.json requirements.txt pyproject.toml go.mod Gemfile composer.json Cargo.toml)
EMBARKO_HAS_MANIFEST=0
for _m in "${EMBARKO_MANIFESTS[@]}"; do
  if [[ -e "$APP_DIR/$_m" ]]; then EMBARKO_HAS_MANIFEST=1; break; fi
done

# Fail fast if the app's manifest (or index.html) is nested one level down
# instead of at $APP_DIR's root — e.g. an archive that unpacked with an
# extra wrapping folder ("myapp/myapp/..."). Embarko's build only looks at
# $APP_DIR's own root; a nested manifest packages into nothing buildable
# there and fails several minutes later, deep inside the build step, with
# a cryptic error (e.g. "npm run build ... exit code: 127") that doesn't
# name the real cause. Only checked when the root has neither a manifest
# nor an index.html — if the root already has something buildable, there's
# nothing to detect here.
if (( EMBARKO_HAS_MANIFEST == 0 )) && [[ ! -e "$APP_DIR/index.html" ]]; then
  EMBARKO_NESTED_HIT=""
  for _d in "$APP_DIR"/*/; do
    [[ -d "$_d" ]] || continue
    case "$(basename "$_d")" in node_modules|.git|.next|dist|venv|__pycache__) continue ;; esac
    for _m in "${EMBARKO_MANIFESTS[@]}" index.html; do
      if [[ -e "${_d}${_m}" ]]; then EMBARKO_NESTED_HIT="${_d}${_m}"; break 2; fi
    done
  done
  if [[ -n "$EMBARKO_NESTED_HIT" ]]; then
    EMBARKO_NESTED_DIR=$(dirname "$EMBARKO_NESTED_HIT")
    echo "ERROR: no app manifest (package.json, requirements.txt, ...) or index.html found" >&2
    echo "    at the root of ${APP_DIR}, but found one in: ${EMBARKO_NESTED_HIT}" >&2
    echo "" >&2
    echo "    Your app files look nested one level too deep — likely an extra wrapping" >&2
    echo "    folder from how this was extracted or downloaded." >&2
    echo "" >&2
    echo "    Fix — point this script at the actual app folder instead:" >&2
    echo "      ./scripts/deploy.sh ${EMBARKO_NESTED_DIR}" >&2
    echo "    (or move everything from inside ${EMBARKO_NESTED_DIR}/ up into ${APP_DIR}/ and rerun)" >&2
    exit 1
  fi
fi
# nullglob so a directory with no .html at all yields an empty array rather
# than the literal pattern; restored immediately, the rest of the script does
# not expect it.
shopt -q nullglob && _EMBARKO_NULLGLOB_WAS_SET=1 || _EMBARKO_NULLGLOB_WAS_SET=0
shopt -s nullglob
EMBARKO_ROOT_HTML=("$APP_DIR"/*.html)
(( _EMBARKO_NULLGLOB_WAS_SET )) || shopt -u nullglob

if [[ ! -e "$APP_DIR/index.html" ]] \
   && (( EMBARKO_HAS_MANIFEST == 0 )) \
   && (( ${#EMBARKO_ROOT_HTML[@]} > 0 )); then
  echo "ERROR: this looks like a static site with no index.html at its root." >&2
  echo "Found instead:" >&2
  printf '  %s\n' "${EMBARKO_ROOT_HTML[@]}" >&2
  echo "Embarko's build detection serves index.html — rename or copy the page" >&2
  echo "to ${APP_DIR}/index.html and run this again." >&2
  exit 1
fi

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
# A token in the environment wins; otherwise fall back to the credential
# file an earlier run saved. Without this fallback the skill's "store it
# and stop asking" instruction would be a lie — the value would sit on
# disk and every later deploy would still go out anonymously.
EMBARKO_CREDENTIALS="${EMBARKO_CREDENTIALS_FILE:-$HOME/.embarko/credentials}"
if [[ -z "${DEPLOY_TOKEN:-}" && -r "$EMBARKO_CREDENTIALS" ]]; then
  # First non-empty, non-comment line, whitespace stripped — a credential
  # file people also hand-edit shouldn't break on a trailing newline.
  DEPLOY_TOKEN=$(grep -v '^[[:space:]]*#' "$EMBARKO_CREDENTIALS" | tr -d '[:space:]' | head -1)
  [[ -n "$DEPLOY_TOKEN" ]] && echo "==> Using the saved credential in ${EMBARKO_CREDENTIALS}."
fi

CURL_AUTH_ARGS=()
if [[ -n "${DEPLOY_TOKEN:-}" ]]; then
  CURL_AUTH_ARGS=(-H "Authorization: Bearer ${DEPLOY_TOKEN}")
else
  echo "==> No DEPLOY_TOKEN set — deploying anonymously: a live but TEMPORARY app,"
  echo "    deleted after 24h unless claimed by redeploying with a real token."
fi

# Landing-page attribution, if this deploy came from one. Same array
# treatment as the auth header above, for the same reason: an unset
# variable must omit the header entirely rather than send an empty one.
CURL_ATTRIBUTION_ARGS=()
if [[ -n "${EMBARKO_LP_VARIANT:-}" ]]; then
  CURL_ATTRIBUTION_ARGS=(-H "lp_variant: ${EMBARKO_LP_VARIANT}")
fi

echo "==> Deploying to ${DEPLOY_URL}"
RESPONSE=$(curl -sS -X POST "$DEPLOY_URL" \
  "${CURL_AUTH_ARGS[@]}" \
  "${CURL_ATTRIBUTION_ARGS[@]}" \
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
    echo "==> Deploy failed (code: ${CODE}) — look this code up before retrying:"
    echo "    scripts/troubleshoot.md, or https://embarko.ai/troubleshoot"
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
APP_URL=$(echo "$RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0)).url' 2>/dev/null || true)

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
    # Printed on its own line, last: this is the one piece of output the
    # caller (or the agent running this) actually reports back to a person,
    # and digging it out of the raw JSON above shouldn't be their job.
    if [[ -n "$APP_URL" && "$APP_URL" != "undefined" ]]; then
      echo "==> Live:"
      echo "$APP_URL"
    fi
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