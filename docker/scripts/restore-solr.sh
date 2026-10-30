#!/usr/bin/env bash
#
# Copy the Solr index in ./data/solr into the solr container's volume.
#
#   ./scripts/restore-solr.sh
#
# Normally called for you by up.sh --fresh. Run it directly if you have
# re-fetched an index and want to swap it in without rebuilding the database.
#
# This deliberately restores ONLY the index data, not the core's conf/
# directory. ArchivesSpace checksums the live Solr schema against the one it
# expects and refuses to start if they differ
# (AppConfig[:solr_verify_checksums]). A conf/ copied from a server running a
# different ArchivesSpace version would therefore break startup, with an error
# that points at Solr rather than at the real cause. Keeping the image's own
# conf/ and dropping in just the index sidesteps that entirely.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; source .env; set +a

if [[ ! -d data/solr ]]; then
  echo "error: data/solr does not exist." >&2
  echo "       Copy the server's 'archivesspace' Solr core directory to" >&2
  echo "       data/solr/archivesspace -- see README.md -- or skip the copy" >&2
  echo "       and build the index locally with ./scripts/reindex.sh." >&2
  exit 1
fi

# People copy from different levels depending on how their server is laid out
# and which directory they grabbed, so accept any of the usual shapes rather
# than failing on a technicality. What we want is the core's data directory:
# the one that contains index/.
if [[ -d data/solr/archivesspace/data/index ]]; then
  SRC="data/solr/archivesspace/data"
elif [[ -d data/solr/data/index ]]; then
  SRC="data/solr/data"
elif [[ -d data/solr/index ]]; then
  SRC="data/solr"
else
  echo "error: no Solr index found under data/solr." >&2
  echo "       Looked for archivesspace/data/index, data/index and index/." >&2
  echo "       Copy the whole 'archivesspace' core directory from the server," >&2
  echo "       so that you end up with data/solr/archivesspace/data/index --" >&2
  echo "       see README.md -- or skip the copy entirely and build the index" >&2
  echo "       locally with ./scripts/reindex.sh." >&2
  exit 1
fi

echo "==> Restoring Solr index from ${SRC}"

# The core must exist before we swap its data, so that the image's own conf/
# is in place. Start Solr once to let solr-precreate do its work.
echo "==> Ensuring the core exists"
docker compose up -d solr >/dev/null
for _ in $(seq 1 60); do
  curl -sf "http://localhost:${SOLR_PORT:-8983}/solr/archivesspace/admin/ping" >/dev/null 2>&1 && break
  sleep 5
done

# Solr must not be running while its index directory is replaced.
docker compose stop solr >/dev/null

# `docker compose cp` writes into the container filesystem; because /var/solr
# is a named volume the contents persist. Doing it this way avoids needing to
# know where Docker keeps the volume on the host, which differs between Docker
# Desktop on macOS and a Linux runner.
echo "==> Replacing index data"
docker compose run --rm --user root --no-deps --entrypoint sh solr -c \
  'rm -rf /var/solr/data/archivesspace/data' >/dev/null
docker compose cp "${SRC}" solr:/var/solr/data/archivesspace/data

# The Solr image runs as uid 8983. Files copied in arrive owned by root, and
# Solr then cannot write to its own index.
docker compose run --rm --user root --no-deps --entrypoint sh solr -c \
  'chown -R 8983:8983 /var/solr/data/archivesspace' >/dev/null

# ArchivesSpace tracks what it has already indexed in data/indexer_state. If
# that is missing while the index is present, ArchivesSpace assumes nothing has
# been indexed and re-crawls the whole repository -- quietly undoing much of
# the point of copying the index down. Carry the state across if we have it.
if [[ -d data/indexer_state || -d data/indexer_pui_state ]]; then
  echo "==> Restoring indexer state"
  docker compose up --no-start archivesspace >/dev/null 2>&1 || true
  for dir in indexer_state indexer_pui_state; do
    [[ -d "data/${dir}" ]] || continue
    docker compose cp "data/${dir}" "archivesspace:/archivesspace/data/${dir}" >/dev/null 2>&1 || true
  done
else
  echo "    note: no indexer state was copied down, so ArchivesSpace will"
  echo "          re-crawl and top the index up on first start. Harmless, but"
  echo "          slow. Set ASPACE_INDEXER_ENABLED=false in .env to prevent it."
fi

echo "==> Starting Solr"
docker compose up -d solr >/dev/null

echo "==> Waiting for the core to load"
for _ in $(seq 1 60); do
  if curl -sf "http://localhost:${SOLR_PORT:-8983}/solr/archivesspace/admin/ping" >/dev/null 2>&1; then
    NUM=$(curl -s "http://localhost:${SOLR_PORT:-8983}/solr/archivesspace/select?q=*:*&rows=0" \
          | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['numFound'])" 2>/dev/null || echo '?')
    echo "==> Solr is up with ${NUM} documents."
    if [[ "${NUM}" == "0" ]]; then
      echo "    Zero documents means the copy did not take. Check that"
      echo "    you copied the core's data directory rather than the core."
    fi
    exit 0
  fi
  printf '.'
  sleep 5
done

echo >&2
echo "error: the core did not load after the restore." >&2
echo >&2
echo "       The usual cause is Solr version skew: Lucene reads its own index" >&2
echo "       format and one major version back, no further. ArchivesSpace" >&2
echo "       ${ASPACE_VERSION:-4.1.1} ships Solr 9.x, so an index from Solr 8.x" >&2
echo "       is fine but one from 7.x or older is not." >&2
echo >&2
echo "       Look at the actual error:  docker compose logs solr" >&2
echo "       Then fall back to:         ./scripts/reindex.sh" >&2
exit 1
