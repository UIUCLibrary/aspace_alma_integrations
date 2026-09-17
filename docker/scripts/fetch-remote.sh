#!/usr/bin/env bash
#
# Pull a copy of a remote ArchivesSpace server's database and Solr index down
# to ./data, ready for ./scripts/up.sh to restore.
#
#   ./scripts/fetch-remote.sh            # database and Solr index
#   ./scripts/fetch-remote.sh --db-only
#   ./scripts/fetch-remote.sh --solr-only
#
# Requires SSH key access to the remote host. Nothing here writes a password
# to disk or to your shell history.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
if [[ -f .env ]]; then
  set -a; source .env; set +a
else
  echo "error: no .env found. Copy .env.example to .env and edit it first." >&2
  exit 1
fi

WANT_DB=true
WANT_SOLR=true

for arg in "$@"; do
  case "$arg" in
    --db-only)   WANT_SOLR=false ;;
    --solr-only) WANT_DB=false ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown option '$arg'" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${REMOTE_HOST:-}" ]]; then
  echo "error: REMOTE_HOST is not set in .env" >&2
  exit 1
fi

SSH_TARGET="${REMOTE_HOST}"
[[ -n "${REMOTE_USER:-}" ]] && SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

echo "==> Mirroring ${SSH_TARGET}"

# --- preflight -------------------------------------------------------------
# Fail here with a clear message rather than halfway through a 4GB transfer.
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_TARGET}" true 2>/dev/null; then
  echo "error: cannot SSH to ${SSH_TARGET} without a password." >&2
  echo "       Set up key authentication first (ssh-copy-id ${SSH_TARGET})." >&2
  exit 1
fi

# --- database --------------------------------------------------------------
if [[ "${WANT_DB}" == true ]]; then
  DUMP_DIR="data/db-dump"
  # Compose applies everything in this directory in filename order on first
  # start, so there must only ever be one dump in it.
  mkdir -p "${DUMP_DIR}"
  rm -f "${DUMP_DIR}"/*.sql "${DUMP_DIR}"/*.sql.gz

  DB_PASS="${REMOTE_DB_PASSWORD:-}"
  if [[ -z "${DB_PASS}" ]]; then
    read -r -s -p "MySQL password for ${REMOTE_DB_USER}@${REMOTE_DB_HOST}: " DB_PASS
    echo
  fi

  echo "==> Dumping ${REMOTE_DB_NAME} (this can take a while on a big repository)"

  # The dump is produced and gzipped on the remote side and streamed over the
  # existing SSH connection, so nothing large is ever written to the server's
  # disk and the transfer is compressed.
  #
  # --single-transaction gives a consistent snapshot without locking tables,
  # so this is safe to run against a server other people are using.
  # --routines and --triggers matter: ArchivesSpace uses both, and a dump
  # without them restores into a subtly broken database.
  #
  # The password is passed via an environment variable on the remote side
  # rather than on the command line, so it does not appear in that server's
  # process list where any other user could read it.
  if ! MYSQL_PWD="${DB_PASS}" ssh "${SSH_TARGET}" \
        "MYSQL_PWD=$(printf '%q' "${DB_PASS}") mysqldump \
           --host=$(printf '%q' "${REMOTE_DB_HOST}") \
           --user=$(printf '%q' "${REMOTE_DB_USER}") \
           --single-transaction \
           --quick \
           --routines \
           --triggers \
           --default-character-set=utf8mb4 \
           --no-tablespaces \
           $(printf '%q' "${REMOTE_DB_NAME}") | gzip -1" \
        > "${DUMP_DIR}/01-archivesspace.sql.gz"; then
    echo "error: mysqldump failed. Check REMOTE_DB_* settings in .env." >&2
    rm -f "${DUMP_DIR}/01-archivesspace.sql.gz"
    exit 1
  fi

  unset DB_PASS

  SIZE=$(du -h "${DUMP_DIR}/01-archivesspace.sql.gz" | cut -f1)
  echo "==> Database dump saved: ${DUMP_DIR}/01-archivesspace.sql.gz (${SIZE})"
fi

# --- solr ------------------------------------------------------------------
if [[ "${WANT_SOLR}" == true ]]; then
  echo "==> Copying Solr index from ${REMOTE_SOLR_DATA}"
  mkdir -p data/solr

  # An index copied while Solr is writing to it can be internally
  # inconsistent. This is a warning rather than a hard stop because on a quiet
  # development server it is usually fine, and because reindex.sh is always
  # available as the reliable alternative.
  if ssh "${SSH_TARGET}" "pgrep -f 'solr' >/dev/null 2>&1"; then
    echo "    note: Solr is running on the remote host. The copy may catch it"
    echo "          mid-write. If the index looks wrong locally, stop Solr"
    echo "          there and re-run, or just use ./scripts/reindex.sh."
  fi

  # -z compresses; --delete keeps repeat runs incremental, which matters
  # because a real index can be several gigabytes.
  if ! rsync -az --delete --info=progress2 \
        "${SSH_TARGET}:${REMOTE_SOLR_DATA}/" data/solr/; then
    echo "error: rsync failed. Check REMOTE_SOLR_DATA in .env, and that your" >&2
    echo "       user can read it on the remote host." >&2
    exit 1
  fi

  echo "==> Solr index saved to data/solr"

  # ArchivesSpace records how far the indexer has got in data/indexer_state.
  # Copying the index without it means ArchivesSpace decides nothing has been
  # indexed and re-crawls everything on first start, which throws away much of
  # the benefit of copying the index at all.
  echo "==> Copying indexer state"
  for dir in indexer_state indexer_pui_state; do
    rsync -az --delete \
      "${SSH_TARGET}:${REMOTE_ASPACE_HOME}/data/${dir}/" "data/${dir}/" 2>/dev/null \
      && echo "    got ${dir}" \
      || echo "    no ${dir} on the remote host (fine -- it will re-crawl)"
  done

  # Version skew here is the single most common reason a copied index refuses
  # to load, and the failure mode is an opaque Lucene exception at startup.
  REMOTE_LUCENE=$(ssh "${SSH_TARGET}" \
    "cat ${REMOTE_SOLR_DATA}/archivesspace/data/index/segments_* 2>/dev/null | head -c 200" \
    2>/dev/null | strings 2>/dev/null | grep -Eo 'Lucene[0-9]+' | head -1 || true)
  if [[ -n "${REMOTE_LUCENE}" ]]; then
    echo "    remote index format: ${REMOTE_LUCENE}"
    echo "    Lucene reads its own and the previous major version only. If"
    echo "    ArchivesSpace ${ASPACE_VERSION:-4.2.1} ships a newer Solr than the"
    echo "    server, run ./scripts/reindex.sh instead of using this copy."
  fi
fi

echo
echo "Done. Next:"
echo "  ./scripts/up.sh --fresh    # restore the dump and start"
