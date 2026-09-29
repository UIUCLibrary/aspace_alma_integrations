#!/usr/bin/env bash
#
# Prepare the Arclight Solr core.
#
#   ./scripts/arclight-solr.sh                     # prepare the configset and start
#   ./scripts/arclight-solr.sh --conf <dir>        # take the configset from here
#   ./scripts/arclight-solr.sh --reset             # throw the Arclight index away and rebuild
#   ./scripts/arclight-solr.sh --status            # is it up, and how many documents
#   ./scripts/arclight-solr.sh --prepare-only      # write the configset, do not start Solr
#
# Arclight is the public discovery front end and Arcflow is the ETL that
# indexes ArchivesSpace into it. Arclight's index lives as a second core in
# the SAME Solr as ArchivesSpace's, which is how the UIUC dev and stage
# servers are laid out, and means both cores are on 8983 -- the port Arcflow
# and Arclight already expect, so neither needs reconfiguring.
#
# This script only prepares the configset on the host. The core itself is
# created inside the container at startup by docker/solr/arclight-core.sh,
# which also adds the is_creator field Arcflow needs.
#
# The configset comes from the Arclight gem, which `arclight:install` copies
# into the app as solr/conf. Arcuit ships no Solr configuration, so the
# downloaded copy of Arclight v1.6.0's configset is the same thing your app
# has. Point ARCLIGHT_SOLR_CONF in .env at your own checkout if you have local
# schema changes:
#
#   ARCLIGHT_SOLR_CONF=/Users/you/code/arclight/solr/conf
#
# See README.md, "Indexing into Arclight with Arcflow", for the whole workflow.

set -euo pipefail

cd "$(dirname "$0")/.."

# Arclight release to fall back to when there is no local checkout to copy
# from. v1.6.0 is what Arcuit pins (`gem 'arclight', '= 1.6.0'` in its
# template.rb), so the downloaded configset matches what UIUC actually run.
ARCLIGHT_FALLBACK_REF="${ARCLIGHT_FALLBACK_REF:-v1.6.0}"

CONF_ARG=""
RESET=false
STATUS_ONLY=false
PREPARE_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf)         CONF_ARG="${2:-}"; shift ;;
    --conf=*)       CONF_ARG="${1#*=}" ;;
    --reset)        RESET=true ;;
    --status)       STATUS_ONLY=true ;;
    --prepare-only) PREPARE_ONLY=true ;;
    -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "arclight-solr.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f .env ]]; then
  echo "error: no .env. Run: cp .env.example .env" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

CORE="${ARCLIGHT_SOLR_CORE:-blacklight-core}"
# Both cores are served by the one Solr, so this is the same port ArchivesSpace
# uses. That is the point: Arclight defaults to 8983 and so does Arcflow.
PORT="${SOLR_PORT:-8983}"
CONF_DEST="data/arclight-solr/conf"
INDEX_SRC="data/arclight-solr/index"

ping_url="http://localhost:${PORT}/solr/${CORE}/admin/ping"
select_url="http://localhost:${PORT}/solr/${CORE}/select?q=*:*&rows=0"

doc_count() {
  curl -s "${select_url}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['numFound'])" 2>/dev/null \
    || echo '?'
}

# --- --status ---------------------------------------------------------------
if [[ "${STATUS_ONLY}" == true ]]; then
  if curl -sf "${ping_url}" >/dev/null 2>&1; then
    echo "Arclight Solr is up at http://localhost:${PORT}/solr/${CORE}"
    echo "  documents: $(doc_count)"
    exit 0
  fi
  echo "Arclight Solr is not answering at http://localhost:${PORT}/solr/${CORE}"
  echo "  Start it with: ./scripts/arclight-solr.sh"
  exit 1
fi

# --- work out where the configset comes from --------------------------------
# In preference order: an explicit --conf, then ARCLIGHT_SOLR_CONF from .env,
# then whatever was prepared on a previous run, then Arclight upstream.
SOURCE="${CONF_ARG:-${ARCLIGHT_SOLR_CONF:-}}"

if [[ -n "${SOURCE}" ]]; then
  # Point at either <app>/solr/conf or <app>/solr -- both are things people
  # reasonably type, and getting it wrong otherwise produces a core with no
  # schema, which fails later and much less clearly.
  if [[ -f "${SOURCE}/schema.xml" ]]; then
    :
  elif [[ -f "${SOURCE}/conf/schema.xml" ]]; then
    SOURCE="${SOURCE}/conf"
  else
    echo "error: no Arclight configset at ${SOURCE}" >&2
    echo "       Expected a directory containing schema.xml and solrconfig.xml." >&2
    echo "       In an Arclight application that is: <app>/solr/conf" >&2
    echo >&2
    echo "       Either fix ARCLIGHT_SOLR_CONF in .env, or unset it to download" >&2
    echo "       Arclight ${ARCLIGHT_FALLBACK_REF}'s own configset instead." >&2
    exit 1
  fi

  echo "==> Copying the Arclight configset from ${SOURCE}"
  rm -rf "${CONF_DEST}"
  mkdir -p "${CONF_DEST}"
  cp -R "${SOURCE}/." "${CONF_DEST}/"

elif [[ -f "${CONF_DEST}/schema.xml" ]]; then
  echo "==> Using the configset already in ${CONF_DEST}"
  echo "    (set ARCLIGHT_SOLR_CONF in .env to refresh it from your Arclight"
  echo "     checkout, which is the copy that matches what you are running)"

else
  echo "==> No Arclight checkout configured, so downloading Arclight ${ARCLIGHT_FALLBACK_REF}'s configset"
  echo "    That is the same configset your Arclight app has -- Arcuit ships"
  echo "    no Solr config of its own. Set ARCLIGHT_SOLR_CONF in .env to use"
  echo "    your checkout instead if you have local schema changes."

  TARBALL="https://codeload.github.com/projectblacklight/arclight/tar.gz/refs/tags/${ARCLIGHT_FALLBACK_REF}"
  TMP=$(mktemp -d)
  trap 'rm -rf "${TMP}"' EXIT

  if ! curl -fsSL "${TARBALL}" -o "${TMP}/arclight.tar.gz"; then
    echo "error: could not download ${TARBALL}" >&2
    echo "       Check your network, or copy the configset in by hand:" >&2
    echo "         ./scripts/arclight-solr.sh --conf /path/to/arclight/solr/conf" >&2
    exit 1
  fi

  # --strip-components drops the arclight-1.6.3/solr/ prefix, leaving the
  # contents of conf/ directly in CONF_DEST.
  rm -rf "${CONF_DEST}"
  mkdir -p "${CONF_DEST}"
  if ! tar -xzf "${TMP}/arclight.tar.gz" -C "${CONF_DEST}" \
         --strip-components=3 --wildcards '*/solr/conf/*' 2>/dev/null; then
    echo "error: the download did not contain solr/conf." >&2
    exit 1
  fi
fi

# --- sanity-check what we ended up with -------------------------------------
for required in schema.xml solrconfig.xml; do
  if [[ ! -f "${CONF_DEST}/${required}" ]]; then
    echo "error: ${CONF_DEST}/${required} is missing -- that is not a usable configset." >&2
    exit 1
  fi
done

# The is_creator field Arcflow needs is NOT added here. It is injected into
# the core's own schema inside the container by docker/solr/arclight-core.sh,
# before Solr starts, so that it is present however the container was brought
# up rather than only when this script was remembered. That also leaves the
# copy below identical to your Arclight checkout.

if [[ "${PREPARE_ONLY}" == true ]]; then
  echo
  echo "==> Configset ready in ${CONF_DEST}. Not starting Solr (--prepare-only)."
  echo "    The core itself is created when the Solr container starts."
  exit 0
fi

# --- reset ------------------------------------------------------------------
# precreate-core does nothing when the core already exists, which is what you
# want on a normal restart and exactly what you do not want after changing the
# configset. Removing the core directory is how you apply one.
#
# Note what this does NOT do: drop the solr-data volume. ArchivesSpace's index
# is on that same volume now, and rebuilding it is a far longer job than
# anything to do with Arclight. Only the Arclight core is removed.
if [[ "${RESET}" == true ]]; then
  echo "==> Removing the Arclight core (ArchivesSpace's index is left alone)"
  docker compose stop solr >/dev/null 2>&1 || true
  # --user root because the core directory is owned by uid 8983 but its parent
  # is not, and --no-deps so this does not drag the database up with it.
  docker compose run --rm --user root --no-deps --entrypoint sh solr -c \
    "rm -rf /var/solr/data/${CORE}" >/dev/null 2>&1 || true
fi

# --- restore a copied index, if there is one --------------------------------
# Optional, and most people will not have one: the whole point of testing
# Arcflow is to build the index rather than copy it. But if someone has pulled
# a core down from a server, put it in place before Solr starts.
RESTORE=false
if [[ -d "${INDEX_SRC}" ]]; then
  if [[ -d "${INDEX_SRC}/index" ]]; then
    RESTORE_SRC="${INDEX_SRC}"
  elif [[ -d "${INDEX_SRC}/data/index" ]]; then
    RESTORE_SRC="${INDEX_SRC}/data"
  elif [[ -d "${INDEX_SRC}/${CORE}/data/index" ]]; then
    RESTORE_SRC="${INDEX_SRC}/${CORE}/data"
  else
    RESTORE_SRC=""
    echo "note: ${INDEX_SRC} exists but has no Lucene index under it."
    echo "      Looked for index/, data/index/ and ${CORE}/data/index/."
    echo "      Ignoring it and starting empty."
  fi

  if [[ -n "${RESTORE_SRC}" ]]; then
    # Only worth doing on a core that has not been indexed into yet --
    # otherwise we would be silently discarding whatever Arcflow has put there.
    if curl -sf "${ping_url}" >/dev/null 2>&1 && [[ "$(doc_count)" != "0" ]]; then
      echo "note: ${INDEX_SRC} is present but the core already holds documents,"
      echo "      so it is being left alone. Use --reset to restore over it."
    else
      RESTORE=true
    fi
  fi
fi

# --- start ------------------------------------------------------------------
# The core is created during container startup, so a Solr that was already
# running before the configset was prepared does not have it yet. Restarting is
# what makes it appear -- otherwise the core 404s for no visible reason.
if curl -sf "${ping_url}" >/dev/null 2>&1 && [[ "${RESET}" != true ]]; then
  echo "==> The ${CORE} core is already up"
elif [[ -n "$(docker compose ps --status running -q solr 2>/dev/null)" ]]; then
  echo "==> Restarting Solr so it creates the ${CORE} core"
  docker compose restart solr >/dev/null
else
  echo "==> Starting Solr"
  docker compose up -d solr >/dev/null
fi

echo "==> Waiting for the ${CORE} core"
UP=false
for _ in $(seq 1 60); do
  if curl -sf "${ping_url}" >/dev/null 2>&1; then UP=true; break; fi
  printf '.'
  sleep 5
done
echo

if [[ "${UP}" != true ]]; then
  echo "error: the ${CORE} core did not come up." >&2
  echo "       Check: docker compose logs solr" >&2
  echo "       Lines from the startup script are prefixed 'arclight-core:'." >&2
  echo >&2
  echo "       If the configset changed since the core was created, Solr will" >&2
  echo "       still be using the old one. Rebuild it with:" >&2
  echo "         ./scripts/arclight-solr.sh --reset" >&2
  exit 1
fi

if [[ "${RESTORE}" == true ]]; then
  echo "==> Restoring the copied index from ${RESTORE_SRC}"
  # Solr must not be running while its index directory is swapped, but the
  # core had to exist first so that its conf/ is in place -- hence starting,
  # waiting, then stopping.
  docker compose stop solr >/dev/null
  docker compose run --rm --user root --no-deps --entrypoint sh solr -c \
    "rm -rf /var/solr/data/${CORE}/data" >/dev/null
  docker compose cp "${RESTORE_SRC}" "solr:/var/solr/data/${CORE}/data"
  # Files arrive owned by root; the Solr image runs as uid 8983 and then
  # cannot write to its own index.
  docker compose run --rm --user root --no-deps --entrypoint sh solr -c \
    "chown -R 8983:8983 /var/solr/data/${CORE}" >/dev/null
  docker compose up -d solr >/dev/null

  for _ in $(seq 1 60); do
    curl -sf "${ping_url}" >/dev/null 2>&1 && break
    printf '.'
    sleep 5
  done
  echo
fi

COUNT=$(doc_count)

echo
echo "==> The Arclight core is up, alongside ArchivesSpace's, on ${PORT}."
echo
echo "  Arclight core     http://localhost:${PORT}/solr/${CORE}"
echo "  ArchivesSpace     http://localhost:${PORT}/solr/archivesspace"
echo "  Admin UI          http://localhost:${PORT}/solr/#/${CORE}"
echo "  Documents         ${COUNT}"
echo
echo "  Both are on Solr's default port, so nothing needs reconfiguring:"
echo "    bin/dev"
echo
echo "  Index into it with Arcflow:"
echo "    python -m arcflow.main \\"
echo "      --arclight-dir /path/to/arclight \\"
echo "      --solr-url http://localhost:${PORT}/solr/${CORE} \\"
echo "      --aspace-solr-url http://localhost:${PORT}/solr/archivesspace"
echo
