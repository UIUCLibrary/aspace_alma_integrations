#!/usr/bin/env bash
#
# Open a shell inside a container.
#
#   ./scripts/shell.sh             # ArchivesSpace
#   ./scripts/shell.sh db          # a MySQL client on the local database
#   ./scripts/shell.sh solr
#
# Useful inside archivesspace: /archivesspace/logs, /archivesspace/data
# (audit report JSON lives under data/), and the mounted plugin at
# /archivesspace/plugins/alma_integrations.

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; source .env; set +a

case "${1:-archivesspace}" in
  db)
    exec docker compose exec db \
      mysql -u"${MYSQL_USER:-as}" -p"${MYSQL_PASSWORD:-as123}" "${MYSQL_DATABASE:-archivesspace}"
    ;;
  *)
    exec docker compose exec "${1:-archivesspace}" /bin/bash
    ;;
esac
