#!/usr/bin/env bash
#
# deploy-render.sh — Deploy Firecrawl to Render via the REST API
#
# Usage:
#   RENDER_API_KEY=rnd_xxx ./scripts/deploy-render.sh
#
# Optional env vars:
#   RENDER_OWNER_ID   — Render owner/team ID (auto-detected if omitted)
#   GITHUB_REPO_URL   — Git repo URL (default: https://github.com/bertodrew/firecrawl)
#   GITHUB_BRANCH     — Branch to deploy (default: main)
#   RENDER_PLAN       — Service plan: free | starter | standard | pro (default: free)
#   RENDER_DB_PLAN    — Database plan: free | basic_256mb | basic_1gb | ... (default: free)
#
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
API="https://api.render.com/v1"
RENDER_API_KEY="${RENDER_API_KEY:?Set RENDER_API_KEY to your Render API key}"
GITHUB_REPO_URL="${GITHUB_REPO_URL:-https://github.com/bertodrew/firecrawl}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RENDER_PLAN="${RENDER_PLAN:-free}"
RENDER_DB_PLAN="${RENDER_DB_PLAN:-free}"

AUTH_HEADER="Authorization: Bearer ${RENDER_API_KEY}"
JSON_HEADER="Content-Type: application/json"
ACCEPT_HEADER="Accept: application/json"

# ── Helpers ──────────────────────────────────────────────────────────────────
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(
    --silent --show-error --fail-with-body
    --request "$method"
    --url "${API}${path}"
    --header "$AUTH_HEADER"
    --header "$ACCEPT_HEADER"
  )
  if [[ -n "$body" ]]; then
    args+=(--header "$JSON_HEADER" --data "$body")
  fi
  curl "${args[@]}"
}

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m  $*"; }
fail() { echo -e "\033[1;31m ✗\033[0m  $*" >&2; exit 1; }
jq_or_fail() { jq -r "$1" 2>/dev/null || fail "Failed to parse JSON response"; }

wait_for_deploy() {
  local service_id="$1" max_wait=600 elapsed=0
  log "Waiting for deploy on service $service_id ..."
  while (( elapsed < max_wait )); do
    local status
    status=$(api GET "/services/${service_id}/deploys?limit=1" | jq -r '.[0].deploy.status // "unknown"')
    case "$status" in
      live)        ok "Deploy is live!"; return 0 ;;
      deactivated) fail "Deploy was deactivated" ;;
      build_failed|update_failed|canceled)
                   fail "Deploy failed with status: $status" ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
    echo "  ... status: $status (${elapsed}s)"
  done
  fail "Timed out waiting for deploy after ${max_wait}s"
}

# ── Step 0: Detect owner ────────────────────────────────────────────────────
log "Detecting Render owner..."
if [[ -z "${RENDER_OWNER_ID:-}" ]]; then
  RENDER_OWNER_ID=$(api GET "/owners" | jq -r '.[0].owner.id')
  [[ "$RENDER_OWNER_ID" == "null" || -z "$RENDER_OWNER_ID" ]] && fail "Could not detect owner ID. Set RENDER_OWNER_ID manually."
fi
ok "Owner ID: $RENDER_OWNER_ID"

# ── Step 1: Create PostgreSQL ───────────────────────────────────────────────
log "Creating PostgreSQL database (firecrawl-postgres)..."
PG_RESPONSE=$(api POST "/postgres" "$(cat <<EOF
{
  "databaseName": "firecrawl",
  "databaseUser": "firecrawl",
  "enableHighAvailability": false,
  "plan": "$RENDER_DB_PLAN",
  "version": "16",
  "name": "firecrawl-postgres",
  "ownerId": "$RENDER_OWNER_ID",
  "ipAllowList": [{"cidrBlock": "0.0.0.0/0", "description": "Allow all"}]
}
EOF
)")
PG_ID=$(echo "$PG_RESPONSE" | jq_or_fail '.id')
PG_INTERNAL_CONN=$(echo "$PG_RESPONSE" | jq_or_fail '.internalConnectionString // .connectionInfo.internalConnectionString // empty')
ok "PostgreSQL created: $PG_ID"

# Wait for Postgres to be available and get connection string
log "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
  PG_INFO=$(api GET "/postgres/$PG_ID")
  PG_STATUS=$(echo "$PG_INFO" | jq -r '.status // "unknown"')
  PG_INTERNAL_CONN=$(echo "$PG_INFO" | jq -r '.internalConnectionString // .connectionInfo.internalConnectionString // empty')
  if [[ "$PG_STATUS" == "available" && -n "$PG_INTERNAL_CONN" ]]; then
    break
  fi
  sleep 10
  echo "  ... postgres status: $PG_STATUS (${i}0s)"
done
[[ -z "$PG_INTERNAL_CONN" ]] && fail "Could not get PostgreSQL connection string"
ok "PostgreSQL ready: $PG_INTERNAL_CONN"

# ── Step 2: Create Key Value (Redis/Valkey) ─────────────────────────────────
log "Creating Key Value store (firecrawl-redis)..."
KV_RESPONSE=$(api POST "/services" "$(cat <<EOF
{
  "type": "keyvalue",
  "name": "firecrawl-redis",
  "ownerId": "$RENDER_OWNER_ID",
  "plan": "$RENDER_PLAN",
  "ipAllowList": [{"cidrBlock": "0.0.0.0/0", "description": "Allow all"}]
}
EOF
)")
KV_ID=$(echo "$KV_RESPONSE" | jq -r '.service.id // .id')
ok "Key Value created: $KV_ID"

# Get Redis connection string
log "Waiting for Key Value store to be ready..."
REDIS_CONN=""
for i in {1..20}; do
  KV_INFO=$(api GET "/services/$KV_ID")
  REDIS_CONN=$(echo "$KV_INFO" | jq -r '.connectionInfo.connectionString // .service.details.connectionString // empty')
  if [[ -n "$REDIS_CONN" ]]; then break; fi
  sleep 5
  echo "  ... waiting (${i}x5s)"
done
[[ -z "$REDIS_CONN" ]] && fail "Could not get Redis connection string"
ok "Key Value ready: $REDIS_CONN"

# ── Step 3: Create Playwright Private Service ───────────────────────────────
log "Creating Playwright private service..."
PW_RESPONSE=$(api POST "/services" "$(cat <<EOF
{
  "type": "private_service",
  "name": "firecrawl-playwright",
  "ownerId": "$RENDER_OWNER_ID",
  "plan": "$RENDER_PLAN",
  "serviceDetails": {
    "env": "docker",
    "dockerfilePath": "./apps/playwright-service-ts/Dockerfile",
    "dockerContext": "./apps/playwright-service-ts",
    "envVars": [
      {"key": "PORT", "value": "3000"}
    ]
  },
  "repo": "$GITHUB_REPO_URL",
  "branch": "$GITHUB_BRANCH",
  "autoDeploy": "yes"
}
EOF
)")
PW_ID=$(echo "$PW_RESPONSE" | jq -r '.service.id // .id')
ok "Playwright service created: $PW_ID"

# Derive Playwright internal URL
PW_INTERNAL_URL="http://firecrawl-playwright:3000/scrape"
# Render uses the service name for internal DNS in the same region
# If that doesn't work, the service URL from the API can be used
PW_SERVICE_URL=$(echo "$PW_RESPONSE" | jq -r '.service.serviceDetails.url // empty')
if [[ -n "$PW_SERVICE_URL" ]]; then
  PW_INTERNAL_URL="${PW_SERVICE_URL}/scrape"
fi

# ── Step 4: Create API Web Service ──────────────────────────────────────────
log "Creating Firecrawl API web service..."
BULL_AUTH_KEY=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32)

API_RESPONSE=$(api POST "/services" "$(cat <<EOF
{
  "type": "web_service",
  "name": "firecrawl-api",
  "ownerId": "$RENDER_OWNER_ID",
  "plan": "$RENDER_PLAN",
  "serviceDetails": {
    "env": "docker",
    "dockerfilePath": "./apps/api/Dockerfile",
    "dockerContext": ".",
    "healthCheckPath": "/",
    "envVars": [
      {"key": "HOST",                      "value": "0.0.0.0"},
      {"key": "PORT",                      "value": "3002"},
      {"key": "NUM_WORKERS_PER_QUEUE",     "value": "8"},
      {"key": "REDIS_URL",                 "value": "$REDIS_CONN"},
      {"key": "REDIS_RATE_LIMIT_URL",      "value": "$REDIS_CONN"},
      {"key": "PLAYWRIGHT_MICROSERVICE_URL","value": "$PW_INTERNAL_URL"},
      {"key": "NUQ_DATABASE_URL",          "value": "$PG_INTERNAL_CONN"},
      {"key": "USE_DB_AUTHENTICATION",     "value": "false"},
      {"key": "LOGGING_LEVEL",             "value": "INFO"},
      {"key": "BULL_AUTH_KEY",             "value": "$BULL_AUTH_KEY"}
    ]
  },
  "repo": "$GITHUB_REPO_URL",
  "branch": "$GITHUB_BRANCH",
  "autoDeploy": "yes"
}
EOF
)")
API_ID=$(echo "$API_RESPONSE" | jq -r '.service.id // .id')
API_URL=$(echo "$API_RESPONSE" | jq -r '.service.serviceDetails.url // empty')
ok "API service created: $API_ID"

# ── Step 5: Wait for API deploy ─────────────────────────────────────────────
wait_for_deploy "$API_ID"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  Firecrawl deployed successfully on Render!"
echo "=============================================="
echo ""
echo "  API URL:        ${API_URL:-https://firecrawl-api.onrender.com}"
echo "  PostgreSQL ID:  $PG_ID"
echo "  Key Value ID:   $KV_ID"
echo "  Playwright ID:  $PW_ID"
echo "  API Service ID: $API_ID"
echo ""
echo "  Dashboard: https://dashboard.render.com"
echo ""
echo "  Test it:"
echo "    curl ${API_URL:-https://firecrawl-api.onrender.com}/"
echo ""
