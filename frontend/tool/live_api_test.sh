#!/usr/bin/env bash
# Runs test/live_api_test.dart, the app's real repositories against a real API.
#
#   tool/live_api_test.sh                      a throwaway API with its own empty
#                                              database; nothing you have is touched
#   API_BASE_URL=http://localhost:8000/api/v1 tool/live_api_test.sh
#                                              an API that is already running; it
#                                              leaves a test patient and a test
#                                              exercise behind in its database
#
# Either way the demo accounts come from backend/.env (the SEED_* values).
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$script")/.."

if [[ -z "${API_BASE_URL:-}" ]]; then
  python="$PWD/../backend/.venv/Scripts/python.exe"
  [[ -x "$python" ]] || python="$PWD/../backend/.venv/bin/python"
  cd ../backend
  # Starts the API, runs this script again with API_BASE_URL set, cleans up.
  exec "$python" -m app.throwaway "$BASH" "$script"
fi

env_file="../backend/.env"
value() { grep -E "^$1=" "$env_file" | head -1 | cut -d= -f2- | tr -d '\r'; }

flutter test test/live_api_test.dart \
  --dart-define=LIVE_API=true \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --dart-define=PHYSIO_EMAIL="$(value SEED_PHYSIO_EMAIL)" \
  --dart-define=PHYSIO_PASSWORD="$(value SEED_PHYSIO_PASSWORD)" \
  --dart-define=ADMIN_EMAIL="$(value SEED_ADMIN_EMAIL)" \
  --dart-define=ADMIN_PASSWORD="$(value SEED_ADMIN_PASSWORD)"
