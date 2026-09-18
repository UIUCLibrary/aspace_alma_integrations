#!/usr/bin/env bash
#
# Start the local stack.
#
#   ./scripts/up.sh              # start (or resume) everything
#   ./scripts/up.sh --fresh      # wipe local volumes and restore from ./data
#   ./scripts/up.sh --logs       # start, then follow the ArchivesSpace log
#
# --fresh is what you want after copying a dump down: MySQL only applies a dump to
# an empty data directory, so an existing database must be removed first.

set -euo pipefail

cd "$(dirname "$0")/.."

FRESH=false
FOLLOW=false

for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=true ;;
    --logs)  FOLLOW=true ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown option '$arg'" >&2
      exit 1
      ;;
  esac
done

# --- preflight -------------------------------------------------------------
if [[ ! -f .env ]]; then
  echo "error: no .env. Run: cp .env.example .env" >&2
  exit 1
fi

if [[ ! -f config/config.rb ]]; then
  echo "error: no config/config.rb." >&2
  echo "       Run: cp config/config.rb.example config/config.rb" >&2
  echo "       then put your Alma sandbox API key in it." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not running." >&2
  exit 1
fi

# Compose v2 is required for the `depends_on: condition: service_healthy`
# syntax used in docker-compose.yml.
if ! docker compose version >/dev/null 2>&1; then
  echo "error: 'docker compose' (v2) not found. Docker Desktop includes it;" >&2
  echo "       on Linux install the docker-compose-plugin package." >&2
  exit 1
fi

# --- warn about emulation --------------------------------------------------
HOST_ARCH=$(uname -m)
if [[ "${HOST_ARCH}" == "arm64" || "${HOST_ARCH}" == "aarch64" ]]; then
  echo "note: ArchivesSpace publishes amd64 images only, so this runs under"
  echo "      emulation on this machine. First start is slow -- 10 minutes is"
  echo "      normal, longer if migrations run. Later starts are quicker."
  echo
fi

# --- guard against changing version under an existing stack -----------------
# Both the database and the Solr index are version-specific once they have been
# used, and neither downgrades:
#
#   Database -- ArchivesSpace migrates forward on first start and has no
#               "down" path. A database that has booted under 4.2.1 is on the
#               4.2.1 schema, and 4.1.1 will refuse it.
#   Solr     -- Lucene reads its own major version and one back, so a 4.1.1
#               index (Lucene 9.8) opens fine under 4.2.1 (Lucene 9.12), but
#               not the other way around. Once 4.2.1 has written to the index,
#               4.1.1 may not be able to open it.
#
# --fresh fixes both: it drops the volumes and rebuilds from ./data, which is
# still whatever was copied down from the server. So this only needs to catch
# the case where the version changed and --fresh was NOT passed.
STAMP=.stack-version
if [[ "${FRESH}" != true && -f "${STAMP}" ]]; then
  PREVIOUS=$(cat "${STAMP}")
  if [[ -n "${PREVIOUS}" && "${PREVIOUS}" != "${ASPACE_VERSION}" ]]; then
    echo "error: ASPACE_VERSION changed from ${PREVIOUS} to ${ASPACE_VERSION}, but the" >&2
    echo "       existing local data was created by ${PREVIOUS}." >&2
    echo >&2
    echo "       The database is on the ${PREVIOUS} schema and ArchivesSpace migrates" >&2
    echo "       forward only. The Solr index may also have been written by a" >&2
    echo "       newer Lucene than ${ASPACE_VERSION} can open." >&2
    echo >&2
    echo "       Rebuild from ./data, which is unchanged:" >&2
    echo >&2
    echo "         ./scripts/up.sh --fresh" >&2
    echo >&2
    echo "       Or put it back with ASPACE_VERSION=${PREVIOUS} in .env." >&2
    exit 1
  fi
fi

# --- fresh start -----------------------------------------------------------
if [[ "${FRESH}" == true ]]; then
  DUMP=$(ls data/db-dump/*.sql data/db-dump/*.sql.gz 2>/dev/null | head -1 || true)
  if [[ -z "${DUMP}" ]]; then
    echo "note: no dump in data/db-dump, so this will be an EMPTY ArchivesSpace"
    echo "      with just the default admin user. If you meant to mirror a"
    echo "      server, copy its dump to data/db-dump/01-archivesspace.sql.gz"
    echo "      first -- see README.md -- and check it with"
    echo "      ./scripts/check-data.sh."
    echo
    read -r -p "Continue with an empty database? [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || exit 1
  else
    echo "==> Will restore: ${DUMP}"
  fi

  echo "==> Removing existing local volumes"
  docker compose down -v --remove-orphans

  # A copied Solr index has to be put in place before Solr starts, which means
  # after the volume is recreated but before the container comes up.
  if [[ -d data/solr/archivesspace ]]; then
    echo "==> Restoring copied Solr index"
    docker compose up --no-start solr
    ./scripts/restore-solr.sh
  fi
fi

echo "==> Starting the database and Solr"
docker compose up -d db solr

# `up -d` returns as soon as the containers have STARTED, not when they are
# ready, and the `docker compose run` below uses --no-deps, which deliberately
# bypasses the depends_on health gate. So nothing here waits for MySQL unless
# we do it explicitly.
#
# That matters most in exactly the case this script exists for. MySQL applies
# data/db-dump on first start, and while it does so the entrypoint runs a
# temporary server that listens on a unix socket only -- no TCP. A multi-GB
# ArchivesSpace dump can take a long time to import, and every TCP connection
# is refused for the whole of it. Running the migrations into that gap fails
# with "Communications link failure ... the driver has not received any
# packets", which looks nothing like "the database is still loading".
#
# The healthcheck pings over TCP, so it only passes once the import has
# finished and the real server is accepting connections. Waiting for it is
# therefore exactly the right gate.
echo "==> Waiting for MySQL to accept connections"
if [[ "${FRESH}" == true ]]; then
  echo "    On a fresh start this includes importing the dump, which for a"
  echo "    large repository can take 20 minutes or more. Nothing is wrong."
fi

DB_DEADLINE=$(( $(date +%s) + 7200 ))
while true; do
  DB_STATUS=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
                "$(docker compose ps -q db 2>/dev/null)" 2>/dev/null || echo starting)

  case "${DB_STATUS}" in
    healthy|running)
      break
      ;;
    exited|dead)
      echo >&2
      echo "error: the database container stopped. Last 40 lines:" >&2
      docker compose logs --tail 40 db >&2
      echo >&2
      echo "  If this happened on --fresh, the dump itself is the usual cause." >&2
      echo "  Check it with ./scripts/check-data.sh." >&2
      exit 1
      ;;
  esac

  if (( $(date +%s) > DB_DEADLINE )); then
    echo >&2
    echo "error: MySQL was still not ready after two hours." >&2
    echo "       Check: docker compose logs db" >&2
    exit 1
  fi

  printf '.'
  sleep 10
done
echo
echo "    ready"

# ArchivesSpace does not migrate the database on startup: it checks the schema
# version and refuses to start if the tables are not there. That is the right
# behaviour on a production server, but it means an empty database -- or one
# restored from a server running an older ArchivesSpace -- needs the migrations
# run explicitly, or the backend just returns 500 with
# "Table 'archivesspace.schema_info' doesn't exist" buried in the log.
#
# setup-database.sh is idempotent: on an already-current database it applies
# nothing and exits cleanly, so it is safe to run on every start.
echo "==> Applying database migrations"
echo "    (no-op if the schema is already current)"
if ! docker compose run --rm --no-deps -T \
       --entrypoint /archivesspace/scripts/setup-database.sh \
       archivesspace > /tmp/aspace-setup-database.log 2>&1; then
  echo
  echo "error: the database migrations failed. The last 20 lines were:" >&2
  tail -20 /tmp/aspace-setup-database.log >&2
  echo >&2
  echo "  Full log: /tmp/aspace-setup-database.log" >&2
  echo >&2

  # Naming the likely cause is only helpful if it is the right one. A
  # connection failure and a genuine migration failure need opposite
  # responses, so tell them apart rather than guessing.
  if grep -qE "CommunicationsException|Communications link failure|Connection refused|DatabaseConnectionError" \
       /tmp/aspace-setup-database.log; then
    echo "  That is a CONNECTION failure, not a schema problem: ArchivesSpace" >&2
    echo "  could not reach MySQL at all. Changing ASPACE_VERSION will not" >&2
    echo "  help. Check that the db container is up and healthy:" >&2
    echo >&2
    echo "    docker compose ps db" >&2
    echo "    docker compose logs db" >&2
  else
    echo "  If the log mentions a schema or migration version, the dump may" >&2
    echo "  be from a NEWER ArchivesSpace than ASPACE_VERSION in .env." >&2
    echo "  ArchivesSpace migrates forward only, so set ASPACE_VERSION to at" >&2
    echo "  least the version the dump came from." >&2
  fi
  exit 1
fi
echo "    done"

# The data is now committed to this version, so record it. The check at the
# top of this script compares against it on the next run.
echo "${ASPACE_VERSION}" > .stack-version

echo "==> Starting ArchivesSpace"
docker compose up -d

echo
echo "==> Waiting for ArchivesSpace to become healthy."
echo "    On a first run with a restored dump this includes database"
echo "    migrations and can take 15 minutes or more. Ctrl-C is safe -- it"
echo "    stops the waiting, not the containers."
echo

# Poll rather than `docker compose wait`, so there is something on screen.
DEADLINE=$(( $(date +%s) + 3600 ))
while true; do
  STATUS=$(docker compose ps --format json archivesspace 2>/dev/null \
            | python3 -c "import sys,json
try:
    raw=sys.stdin.read().strip()
    if not raw: print('starting'); raise SystemExit
    first=raw.splitlines()[0]
    print(json.loads(first).get('Health') or json.loads(first).get('State') or 'starting')
except Exception:
    print('starting')" 2>/dev/null || echo starting)

  case "${STATUS}" in
    healthy)
      break
      ;;
    exited|dead)
      echo "error: the archivesspace container stopped. Last 40 lines:" >&2
      docker compose logs --tail 40 archivesspace >&2
      exit 1
      ;;
  esac

  if (( $(date +%s) > DEADLINE )); then
    echo "error: gave up after an hour. Check: docker compose logs archivesspace" >&2
    exit 1
  fi

  printf '.'
  sleep 10
done

echo
echo "==> Up."
echo
echo "  Staff interface   http://localhost:${STAFF_PORT:-8080}"
echo "  Public interface  http://localhost:${PUBLIC_PORT:-8081}"
echo "  Backend API       http://localhost:${BACKEND_PORT:-8089}"
echo "  Solr              http://localhost:${SOLR_PORT:-8983}/solr"
echo
if [[ -n "$(ls data/db-dump/*.sql data/db-dump/*.sql.gz 2>/dev/null || true)" ]]; then
  echo "  Log in with an account from the mirrored server."
else
  echo "  Log in as admin / admin."
fi
echo
echo "  Plugin:  Repository menu -> Plugins -> Alma Integrations"
echo "  Jobs:    Create -> Job -> Alma Audit"
echo

if [[ "${FOLLOW}" == true ]]; then
  docker compose logs -f archivesspace
fi
