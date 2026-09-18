#!/usr/bin/env bash
#
# Load the copied-down dump into the running database.
#
#   ./scripts/load-db.sh            # load if the database is empty
#   ./scripts/load-db.sh --force    # load even if it already has tables
#
# Normally called for you by up.sh. Run it directly if you have copied down a
# newer dump and want to reload it without rebuilding everything else.
#
# This used to happen implicitly: data/db-dump was mounted at MySQL's
# /docker-entrypoint-initdb.d, which the entrypoint applies on the first start
# of an empty data directory. That worked, but it was a bad place to debug.
# The import ran inside the entrypoint before the server accepted TCP
# connections, so:
#
#   * there was no progress to watch -- a large dump just looked hung;
#   * a failure part way through left a half-loaded database, and the error
#     was buried in the container log rather than returned to you;
#   * you could not retry the load without destroying the volume, because the
#     entrypoint only runs it on an EMPTY data directory;
#   * every other step had to wait behind an opaque black box.
#
# Doing it as its own step costs nothing and fixes all four: the server is up
# and healthy first, the load is an ordinary client connection whose exit
# status we can check, and it can be re-run.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; source .env; set +a

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

DB_NAME="${MYSQL_DATABASE:-archivesspace}"
DB_PASS="${MYSQL_ROOT_PASSWORD:-root123}"

DUMP=$(ls data/db-dump/*.sql data/db-dump/*.sql.gz 2>/dev/null | head -1 || true)
if [[ -z "${DUMP}" ]]; then
  echo "==> No dump in data/db-dump, leaving the database empty."
  exit 0
fi

# MYSQL_PWD keeps the password off the command line, which otherwise makes
# MySQL print a warning on every single invocation.
mysql_do() {
  docker compose exec -T -e MYSQL_PWD="${DB_PASS}" db \
    mysql --default-character-set=utf8mb4 -u root -N -B "$@"
}

EXISTING=$(mysql_do -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" \
  2>/dev/null | tr -d '[:space:]' || echo 0)

if [[ "${EXISTING}" =~ ^[0-9]+$ ]] && (( EXISTING > 0 )) && [[ "${FORCE}" == false ]]; then
  echo "==> Database already has ${EXISTING} tables, skipping the dump load."
  echo "    Use ./scripts/load-db.sh --force to load it again, or"
  echo "    ./scripts/up.sh --fresh to start from scratch."
  exit 0
fi

SIZE=$(du -h "${DUMP}" | cut -f1)
echo "==> Loading ${DUMP} (${SIZE}) into '${DB_NAME}'"
echo "    Reporting the size of the data directory as it goes, so you can"
echo "    tell it apart from a hang."

READER=(cat "${DUMP}")
[[ "${DUMP}" == *.gz ]] && READER=(gzip -dc "${DUMP}")

LOG=/tmp/aspace-load-db.log
START=$(date +%s)

# Run the load in the background so this script can report progress while it
# works. The subshell means $! is one process whose exit status reflects the
# whole pipeline (pipefail is set above), so a failure in gzip is not lost.
(
  "${READER[@]}" | docker compose exec -T -e MYSQL_PWD="${DB_PASS}" db \
    mysql --default-character-set=utf8mb4 -u root "${DB_NAME}"
) > "${LOG}" 2>&1 &
LOAD_PID=$!

DB_CID=$(docker compose ps -q db 2>/dev/null || true)
TICK=0
while kill -0 "${LOAD_PID}" 2>/dev/null; do
  sleep 10
  TICK=$(( TICK + 1 ))
  if (( TICK % 6 == 0 )); then
    ELAPSED=$(( $(date +%s) - START ))
    DATADIR=$(docker exec "${DB_CID}" du -sm /var/lib/mysql 2>/dev/null | cut -f1 || true)
    printf '  %dm%02ds  data directory: %sM\n' \
      $(( ELAPSED / 60 )) $(( ELAPSED % 60 )) "${DATADIR:-?}"
  else
    printf '.'
  fi
done
echo

if ! wait "${LOAD_PID}"; then
  echo "error: loading the dump failed. Last 20 lines:" >&2
  tail -20 "${LOG}" >&2
  echo >&2
  echo "  Full log: ${LOG}" >&2
  echo >&2
  echo "  A dump that is truncated or was written by a newer MySQL is the" >&2
  echo "  usual cause. Check it with ./scripts/check-data.sh." >&2
  exit 1
fi

# Verify rather than assume. A dump can apply without error and still be the
# wrong thing -- a schema-only dump, or one from a different application.
TABLES=$(mysql_do -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" \
  | tr -d '[:space:]')

if ! [[ "${TABLES}" =~ ^[0-9]+$ ]] || (( TABLES == 0 )); then
  echo "error: the dump applied but '${DB_NAME}' still has no tables." >&2
  echo "       Check that the dump actually contains this database." >&2
  exit 1
fi

if ! mysql_do -e "SELECT 1 FROM ${DB_NAME}.schema_info LIMIT 1" >/dev/null 2>&1; then
  echo "warning: loaded ${TABLES} tables, but there is no schema_info table." >&2
  echo "         That is ArchivesSpace's own version marker, so this may not" >&2
  echo "         be an ArchivesSpace dump. Continuing anyway." >&2
else
  VERSION=$(mysql_do -e "SELECT version FROM ${DB_NAME}.schema_info LIMIT 1" | tr -d '[:space:]')
  echo "    schema_info version: ${VERSION}"
fi

RESOURCES=$(mysql_do -e "SELECT COUNT(*) FROM ${DB_NAME}.resource" 2>/dev/null | tr -d '[:space:]' || echo "?")

printf '    loaded %s tables in %dm%02ds (resources: %s)\n' \
  "${TABLES}" $(( ( $(date +%s) - START ) / 60 )) $(( ( $(date +%s) - START ) % 60 )) \
  "${RESOURCES:-?}"
