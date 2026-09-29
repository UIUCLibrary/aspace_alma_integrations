#!/usr/bin/env bash
#
# Prepare and start the Arclight Solr core.
#
#   ./scripts/arclight-solr.sh                     # prepare the configset and start
#   ./scripts/arclight-solr.sh --conf <dir>        # take the configset from here
#   ./scripts/arclight-solr.sh --reset             # throw the index away and rebuild the core
#   ./scripts/arclight-solr.sh --status            # is it up, and how many documents
#   ./scripts/arclight-solr.sh --prepare-only      # write the configset, do not start Solr
#
# This is the Solr that Arclight -- the public discovery front end -- reads
# from, and that Arcflow indexes into. It is entirely separate from the
# ArchivesSpace Solr on 8983: different schema, different core, different
# container.
#
# The configset comes from your own Arclight checkout, which is the only copy
# guaranteed to match the Arclight and Arcuit you are actually running. Point
# ARCLIGHT_SOLR_CONF in .env at it:
#
#   ARCLIGHT_SOLR_CONF=/Users/you/code/arclight/solr/conf
#
# Without that this falls back to downloading Arclight's stock configset, which
# is enough to index against but will not have any Arcuit customisations.
#
# See README.md, "Indexing into Arclight with Arcflow", for the whole workflow.

set -euo pipefail

cd "$(dirname "$0")/.."

# Arclight release to fall back to when there is no local checkout to copy
# from. Pinned rather than tracking main so that two people running this get
# the same schema.
ARCLIGHT_FALLBACK_REF="${ARCLIGHT_FALLBACK_REF:-v1.6.3}"

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
    -h|--help)      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
PORT="${ARCLIGHT_SOLR_PORT:-8984}"
CONF_DEST="data/arclight-solr/conf"
INDEX_SRC="data/arclight-solr/index"

# Everything below drives Compose, and the service sits behind the `arclight`
# profile so that it does not exist at all for people who are not indexing.
# Rather than making every invocation pass --profile, export it -- which also
# means scripts/up.sh, down.sh and logs.sh pick the service up once .env says
# COMPOSE_PROFILES=arclight.
if [[ ",${COMPOSE_PROFILES:-}," != *",arclight,"* ]]; then
  export COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}arclight"
fi

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
  echo "    Set ARCLIGHT_SOLR_CONF in .env to use your own instead -- yours is"
  echo "    the one that carries any Arcuit changes."

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

# --- add the field Arcflow needs and Arclight does not ship ------------------
# Arcflow marks its creator documents with a boolean `is_creator` so they can
# be told apart from collections. That is not one of Arclight's fields, and it
# does not match any of the dynamic field patterns (*_ssim, *_tesim and so on),
# so indexing creators into a stock Arclight core fails with:
#
#   ERROR: [doc=creator_corporate_entities_584] unknown field 'is_creator'
#
# Arcflow's README says to add it through Solr's Schema API. That cannot work
# here: Arclight's solrconfig.xml sets
#
#   <schemaFactory class="ClassicIndexSchemaFactory"/>
#
# which makes the schema read-only at runtime -- the Schema API returns 400.
# The field has to be in schema.xml before the core is created, so put it
# there, in our copy, leaving your Arclight checkout untouched.
if grep -q 'name="is_creator"' "${CONF_DEST}/schema.xml"; then
  echo "==> is_creator is already in the schema"
else
  echo "==> Adding the is_creator field Arcflow's creator records need"
  python3 - "${CONF_DEST}/schema.xml" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as handle:
    schema = handle.read()

field = (
    '\n   <!-- Added by aspace_alma_integrations/docker/scripts/arclight-solr.sh.\n'
    '        Arcflow marks creator documents with this so they can be told apart\n'
    '        from collections. It is not part of stock Arclight, and because this\n'
    '        configset uses ClassicIndexSchemaFactory it cannot be added through\n'
    '        the Schema API at runtime. -->\n'
    '   <field name="is_creator" type="boolean" indexed="true" stored="true" '
    'multiValued="false" />\n'
)

anchor = '<field name="timestamp"'
index = schema.find(anchor)
if index == -1:
    # No timestamp field to sit beside, so fall back to the end of the
    # <fields> block, or to just before </schema> if this configset has none.
    for closing in ('</fields>', '</schema>'):
        index = schema.find(closing)
        if index != -1:
            schema = schema[:index] + field + schema[index:]
            break
    else:
        raise SystemExit('could not find anywhere to add is_creator in %s' % path)
else:
    line_start = schema.rfind('\n', 0, index) + 1
    schema = schema[:line_start] + field.lstrip('\n') + schema[line_start:]

with open(path, 'w', encoding='utf-8') as handle:
    handle.write(schema)
PY

  # A schema Solr cannot parse gives an error at core load that points at the
  # core rather than at this edit, so check it here while the cause is obvious.
  if ! python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" \
         "${CONF_DEST}/schema.xml" >/dev/null 2>&1; then
    echo "error: adding is_creator left schema.xml unparseable. Not starting Solr." >&2
    echo "       Re-run to rebuild the configset from source." >&2
    exit 1
  fi
fi

if [[ "${PREPARE_ONLY}" == true ]]; then
  echo
  echo "==> Configset ready in ${CONF_DEST}. Not starting Solr (--prepare-only)."
  exit 0
fi

# --- reset ------------------------------------------------------------------
# solr-precreate does nothing when the core already exists, which is what you
# want on a normal restart and exactly what you do not want after changing the
# configset. Dropping the volume is the honest way to apply one.
if [[ "${RESET}" == true ]]; then
  echo "==> Removing the existing Arclight index"
  docker compose stop arclight-solr >/dev/null 2>&1 || true
  docker compose rm -fsv arclight-solr >/dev/null 2>&1 || true
  docker volume rm -f aspace-alma_arclight-solr-data >/dev/null 2>&1 || true
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

echo "==> Starting Arclight Solr"
docker compose up -d arclight-solr >/dev/null

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
  echo "       Check: docker compose logs arclight-solr" >&2
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
  docker compose stop arclight-solr >/dev/null
  docker compose run --rm --user root --no-deps --entrypoint sh arclight-solr -c \
    "rm -rf /var/solr/data/${CORE}/data" >/dev/null
  docker compose cp "${RESTORE_SRC}" "arclight-solr:/var/solr/data/${CORE}/data"
  # Files arrive owned by root; the Solr image runs as uid 8983 and then
  # cannot write to its own index.
  docker compose run --rm --user root --no-deps --entrypoint sh arclight-solr -c \
    "chown -R 8983:8983 /var/solr/data/${CORE}" >/dev/null
  docker compose up -d arclight-solr >/dev/null

  for _ in $(seq 1 60); do
    curl -sf "${ping_url}" >/dev/null 2>&1 && break
    printf '.'
    sleep 5
  done
  echo
fi

COUNT=$(doc_count)

echo
echo "==> Arclight Solr is up."
echo
echo "  Core       http://localhost:${PORT}/solr/${CORE}"
echo "  Admin UI   http://localhost:${PORT}/solr/#/${CORE}"
echo "  Documents  ${COUNT}"
echo
echo "  Point Arclight at it (it defaults to 8983, which is ArchivesSpace's):"
echo "    SOLR_URL=http://localhost:${PORT}/solr/${CORE} bin/dev"
echo
echo "  Index into it with Arcflow:"
echo "    python -m arcflow.main \\"
echo "      --arclight-dir /path/to/arclight \\"
echo "      --solr-url http://localhost:${PORT}/solr/${CORE} \\"
echo "      --aspace-solr-url http://localhost:${SOLR_PORT:-8983}/solr/archivesspace"
echo
