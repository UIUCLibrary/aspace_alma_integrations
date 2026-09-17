#!/usr/bin/env bash
#
# Follow logs.
#
#   ./scripts/logs.sh              # ArchivesSpace
#   ./scripts/logs.sh solr         # a named service
#   ./scripts/logs.sh --jobs       # just background job output
#
# --jobs is the one you want when watching an Alma audit run.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--jobs" ]]; then
  docker compose logs -f archivesspace | grep --line-buffered -Ei 'job|alma|audit|index'
else
  docker compose logs -f "${1:-archivesspace}"
fi
