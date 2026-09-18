#!/usr/bin/env bash
#
# Check that the data you copied down from the server is where the containers
# expect to find it, and named what they expect it to be named.
#
#   ./scripts/check-data.sh
#
# Run this before ./scripts/up.sh --fresh. Everything it looks for is optional
# -- you can start with an empty database and no index -- so this reports what
# it found rather than insisting on a particular arrangement.
#
# See README.md, "Copying the data down from a server", for what to copy.

set -euo pipefail

cd "$(dirname "$0")/.."

PROBLEMS=0
WARNINGS=0

problem() { echo "  [X] $*"; PROBLEMS=$((PROBLEMS + 1)); }
warn()    { echo "  [!] $*"; WARNINGS=$((WARNINGS + 1)); }
ok()      { echo "  [ok] $*"; }

echo "Looking in $(pwd)/data"
echo

# --- database dump ---------------------------------------------------------
echo "Database dump -- data/db-dump/"

shopt -s nullglob
DUMPS=(data/db-dump/*.sql data/db-dump/*.sql.gz)
shopt -u nullglob

if [[ ${#DUMPS[@]} -eq 0 ]]; then
  warn "no dump found. ArchivesSpace will start empty, with admin/admin."
  echo "       Expected: data/db-dump/01-archivesspace.sql.gz"
elif [[ ${#DUMPS[@]} -gt 1 ]]; then
  # load-db.sh loads the first match and ignores the rest, so a stale dump
  # sorting ahead of the new one silently gets loaded instead of it.
  problem "more than one dump in data/db-dump. Only the first is loaded and"
  echo "       the rest are ignored. Keep exactly one:"
  for d in "${DUMPS[@]}"; do echo "         ${d}"; done
else
  DUMP="${DUMPS[0]}"
  SIZE=$(du -h "${DUMP}" | cut -f1)
  ok "${DUMP} (${SIZE})"

  # A dump that is really an HTML error page, or was truncated mid-transfer,
  # fails hours later as a confusing SQL syntax error. Cheap to catch now.
  if [[ "${DUMP}" == *.gz ]]; then
    if ! gzip -t "${DUMP}" 2>/dev/null; then
      problem "that file is not valid gzip. Did the download finish?"
    else
      HEAD=$(gzip -cd "${DUMP}" 2>/dev/null | head -c 2000 || true)
    fi
  else
    HEAD=$(head -c 2000 "${DUMP}" 2>/dev/null || true)
  fi

  if [[ -n "${HEAD:-}" ]]; then
    if ! grep -qiE "mysql dump|CREATE TABLE|INSERT INTO|DROP TABLE" <<<"${HEAD}"; then
      problem "that does not look like a MySQL dump."
    fi

    # ArchivesSpace uses stored functions and triggers. A dump taken without
    # --routines --triggers restores into a database that looks complete and
    # then misbehaves, so it is worth flagging even though it is only a hint.
    if ! grep -qiE "CREATE.*(TRIGGER|FUNCTION|PROCEDURE)|DEFINER=" <<<"${HEAD}"; then
      warn "no routines or triggers visible near the top of the dump."
      echo "       If it was taken without --routines --triggers, re-take it;"
      echo "       ArchivesSpace needs both. (This check only reads the first"
      echo "       couple of KB, so it can be a false alarm.)"
    fi
  fi
fi

echo

# --- solr index ------------------------------------------------------------
echo "Solr index -- data/solr/"

if [[ ! -d data/solr ]]; then
  warn "no index copied. Start without one and run ./scripts/reindex.sh,"
  echo "       which is the more reliable route anyway."
else
  # Accept the layouts people actually end up with, depending on whether they
  # copied the core directory, its parent, or just the data directory.
  if   [[ -d data/solr/archivesspace/data/index ]]; then SRC=data/solr/archivesspace/data
  elif [[ -d data/solr/data/index ]];               then SRC=data/solr/data
  elif [[ -d data/solr/index ]];                    then SRC=data/solr
  else SRC=""
  fi

  if [[ -z "${SRC}" ]]; then
    problem "data/solr exists but has no Lucene index in it."
    echo "       Looked for archivesspace/data/index, data/index and index/."
    echo "       Copy the whole 'archivesspace' core directory from the"
    echo "       server, so that you end up with:"
    echo "         data/solr/archivesspace/data/index/"
    echo "       Found instead:"
    find data/solr -maxdepth 2 -mindepth 1 2>/dev/null | head -8 | sed 's/^/         /'
  else
    SIZE=$(du -sh "${SRC}" 2>/dev/null | cut -f1)
    ok "${SRC}/index (${SIZE})"

    # Lucene opens an index written by its own major version or the one
    # before. Version skew is the most common reason a copied index refuses to
    # load, and the failure is an opaque exception at startup, so name it here
    # while there is still an obvious alternative.
    FMT=$(cat "${SRC}"/index/segments_* 2>/dev/null \
          | strings 2>/dev/null | grep -Eo 'Lucene[0-9]+' | head -1 || true)
    if [[ -n "${FMT}" ]]; then
      echo "       index format: ${FMT}"
      echo "       ArchivesSpace ${ASPACE_VERSION:-4.1.1} ships Solr 9 (Lucene 9)."
      echo "       Lucene reads its own major version and the one before it, so"
      echo "       Lucene 8 or 9 will open and anything older will not. If it"
      echo "       fails, ./scripts/reindex.sh always works."
    fi
  fi
fi

echo

# --- indexer state ---------------------------------------------------------
echo "Indexer state -- data/indexer_state/, data/indexer_pui_state/"

FOUND_STATE=false
for dir in indexer_state indexer_pui_state; do
  if [[ -d "data/${dir}" ]]; then
    ok "data/${dir}"
    FOUND_STATE=true
  fi
done

if [[ "${FOUND_STATE}" == false ]]; then
  if [[ -n "${SRC:-}" ]]; then
    # Without this, ArchivesSpace concludes it has indexed nothing and
    # re-crawls the whole repository, which throws away most of the benefit of
    # having copied the index at all.
    warn "none copied, but you did copy an index. ArchivesSpace will not know"
    echo "       how far the indexer got and will re-crawl everything on first"
    echo "       start. Harmless but slow. Either copy these two directories"
    echo "       too, or set ASPACE_INDEXER_ENABLED=false in .env."
  else
    ok "none needed (no index copied)"
  fi
fi

echo

# --- ownership -------------------------------------------------------------
# The containers run as unprivileged users, so a file the host copied down as
# root, or with restrictive permissions, is unreadable inside the container.
UNREADABLE=$(find data -maxdepth 3 ! -readable 2>/dev/null | head -3 || true)
if [[ -n "${UNREADABLE}" ]]; then
  problem "some files under data/ are not readable by you:"
  sed 's/^/         /' <<<"${UNREADABLE}"
  echo "       Try: sudo chown -R \"\$(id -u):\$(id -g)\" data"
  echo
fi

# --- verdict ---------------------------------------------------------------
if [[ ${PROBLEMS} -gt 0 ]]; then
  echo "${PROBLEMS} problem(s) to fix before starting."
  exit 1
fi

if [[ ${WARNINGS} -gt 0 ]]; then
  echo "Nothing blocking (${WARNINGS} thing(s) worth reading above)."
else
  echo "All good."
fi

echo
echo "Next:  ./scripts/up.sh --fresh"
