#!/usr/bin/env bash
#
# Stop the stack.
#
#   ./scripts/down.sh            # stop containers, keep data
#   ./scripts/down.sh --clean    # stop and delete local volumes too
#
# --clean removes the local database, Solr index and job output. It does NOT
# touch ./data, so whatever you fetched from the remote server is still there
# and ./scripts/up.sh --fresh can restore it again.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--clean" ]]; then
  echo "This deletes the local database, Solr index and any audit reports."
  echo "Your fetched copies in ./data are kept."
  read -r -p "Continue? [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || exit 1
  docker compose down -v --remove-orphans
  echo "==> Volumes removed. Restore with: ./scripts/up.sh --fresh"
else
  docker compose down
  echo "==> Stopped. Data kept; restart with ./scripts/up.sh"
fi
