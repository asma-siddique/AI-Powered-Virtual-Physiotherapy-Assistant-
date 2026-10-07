#!/usr/bin/env bash
# Runs test/live_api_test.dart against a running local API, using the demo
# accounts from backend/.env (created by `python -m app.seed`).
set -euo pipefail
cd "$(dirname "$0")/.."

env_file="../backend/.env"
value() { grep -E "^$1=" "$env_file" | head -1 | cut -d= -f2- | tr -d '\r'; }

flutter test test/live_api_test.dart \
  --dart-define=LIVE_API=true \
  --dart-define=API_BASE_URL="${API_BASE_URL:-http://localhost:8000/api/v1}" \
  --dart-define=PHYSIO_EMAIL="$(value SEED_PHYSIO_EMAIL)" \
  --dart-define=PHYSIO_PASSWORD="$(value SEED_PHYSIO_PASSWORD)" \
  --dart-define=ADMIN_EMAIL="$(value SEED_ADMIN_EMAIL)" \
  --dart-define=ADMIN_PASSWORD="$(value SEED_ADMIN_PASSWORD)"
