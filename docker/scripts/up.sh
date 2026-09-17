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
  echo "  A common cause is a dump taken from a NEWER ArchivesSpace than" >&2
  echo "  ASPACE_VERSION in .env. ArchivesSpace migrates forward only, so" >&2
  echo "  set ASPACE_VERSION to at least the version the dump came from." >&2
  exit 1
fi
echo "    done"

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
