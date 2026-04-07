#!/usr/bin/env bash
#
# teardown-render.sh — Remove all Firecrawl services from Render
#
# Usage:
#   RENDER_API_KEY=rnd_xxx ./scripts/teardown-render.sh
#
set -euo pipefail

API="https://api.render.com/v1"
RENDER_API_KEY="${RENDER_API_KEY:?Set RENDER_API_KEY to your Render API key}"
AUTH_HEADER="Authorization: Bearer ${RENDER_API_KEY}"
ACCEPT_HEADER="Accept: application/json"

api() {
  local method="$1" path="$2"
  curl --silent --show-error --fail-with-body \
    --request "$method" \
    --url "${API}${path}" \
    --header "$AUTH_HEADER" \
    --header "$ACCEPT_HEADER"
}

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m  $*"; }
warn() { echo -e "\033[1;33m !\033[0m  $*"; }

PREFIX="firecrawl-"

# Delete services
log "Finding Firecrawl services..."
SERVICES=$(api GET "/services?limit=100" | jq -r ".[] | select(.service.name | startswith(\"$PREFIX\")) | .service.id")

for sid in $SERVICES; do
  NAME=$(api GET "/services/$sid" | jq -r '.name // .service.name // "unknown"')
  log "Deleting service: $NAME ($sid)"
  api DELETE "/services/$sid" > /dev/null 2>&1 && ok "Deleted $NAME" || warn "Failed to delete $NAME"
done

# Delete postgres instances
log "Finding Firecrawl Postgres instances..."
PG_INSTANCES=$(api GET "/postgres?limit=100" | jq -r ".[] | select(.postgres.name | startswith(\"$PREFIX\")) | .postgres.id")

for pid in $PG_INSTANCES; do
  NAME=$(api GET "/postgres/$pid" | jq -r '.name // .postgres.name // "unknown"')
  log "Deleting Postgres: $NAME ($pid)"
  api DELETE "/postgres/$pid" > /dev/null 2>&1 && ok "Deleted $NAME" || warn "Failed to delete $NAME"
done

echo ""
ok "Teardown complete."
