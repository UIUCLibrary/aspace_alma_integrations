#!/usr/bin/env bash
#
# Throw away the local Solr index and have ArchivesSpace rebuild it from the
# database.
#
#   ./scripts/reindex.sh
#
# This is the reliable alternative to copying an index down. It is slower --
# tens of minutes for a large repository, more under emulation -- but it
# cannot fail on a Solr version mismatch, and the result is guaranteed to
# match the database you actually restored.
#
# Use it when:
#   * restore-solr.sh failed with a Lucene version error;
#   * search results do not match what is in the database;
#   * you edited records directly in MySQL.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; source .env; set +a

echo "This deletes the local Solr index and rebuilds it from the database."
read -r -p "Continue? [y/N] " reply
[[ "${reply}" =~ ^[Yy]$ ]] || exit 1

echo "==> Stopping ArchivesSpace so it cannot write while we clear the index"
docker compose stop archivesspace

echo "==> Deleting all documents from the Solr core"
curl -sf -X POST \
  "http://localhost:${SOLR_PORT:-8983}/solr/archivesspace/update?commit=true" \
  -H 'Content-Type: text/xml' \
  --data '<delete><query>*:*</query></delete>' >/dev/null

# ArchivesSpace keeps high-water marks in data/indexer_state. Without removing
# these it believes everything is already indexed and will not rebuild.
echo "==> Clearing indexer state"
docker compose run --rm --no-deps --entrypoint sh archivesspace -c \
  'rm -rf /archivesspace/data/indexer_state /archivesspace/data/indexer_pui_state' >/dev/null

if [[ "${ASPACE_INDEXER_ENABLED:-true}" != "true" ]]; then
  echo
  echo "note: ASPACE_INDEXER_ENABLED is not 'true' in .env, so ArchivesSpace"
  echo "      will not actually index anything. Set it to true and re-run."
  echo
fi

echo "==> Starting ArchivesSpace; indexing begins automatically"
docker compose up -d archivesspace

echo
echo "Indexing runs in the background. Watch it with:"
echo "  docker compose logs -f archivesspace | grep -i index"
echo
echo "Check progress with:"
echo "  curl -s 'http://localhost:${SOLR_PORT:-8983}/solr/archivesspace/select?q=*:*&rows=0'"
