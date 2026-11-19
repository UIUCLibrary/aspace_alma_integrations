#!/usr/bin/env bash
#
# Create the Arclight core, and add the one field Arcflow needs that Arclight
# does not ship.
#
# This runs INSIDE the Solr container, before Solr starts. The official Solr
# image sources every *.sh in /docker-entrypoint-initdb.d, and `solr-precreate`
# does that (via run-initdb) before it creates its own core and execs Solr. So
# by the time Solr reads any schema, everything below has already happened.
#
# Doing it here rather than on the host means the core is correct however the
# container was started -- `docker compose up`, a restart, a rebuilt volume,
# someone else's machine -- instead of only when a helper script was
# remembered.
#
# It is deliberately quiet and non-fatal when there is no Arclight configset
# mounted: this same image serves ArchivesSpace, and nobody working on the
# plugin should have their Solr fail to start over an Arclight feature they
# are not using.

# NOTE: this file is *sourced* by run-initdb, not executed, so it shares the
# entrypoint's shell. A bare `exit` here would abort Solr startup entirely.
# Everything therefore happens in a subshell, whose failure we catch and
# report rather than letting it take Solr down with it.
(
  set -eu

  CORE="${ARCLIGHT_SOLR_CORE:-blacklight-core}"

  # A configset directory, i.e. one that CONTAINS conf/ -- that is the layout
  # precreate-core expects, and it is what the compose file mounts.
  CONFIGSET_DIR=/arclight-configset
  CONF_DIR="${CONFIGSET_DIR}/conf"
  CORE_DIR="/var/solr/data/${CORE}"
  SCHEMA="${CORE_DIR}/conf/schema.xml"

  # Compose always mounts this path, because a bind mount cannot be made
  # conditional. An empty directory therefore means "not using Arclight",
  # which is the common case and not a problem.
  if [ ! -f "${CONF_DIR}/schema.xml" ]; then
    echo "arclight-core: no configset at ${CONF_DIR}, skipping the Arclight core"
    exit 0
  fi

  # No-op when the core already exists, which is what we want on a restart:
  # the index is left alone and only the schema patch below is re-applied.
  precreate-core "${CORE}" "${CONFIGSET_DIR}"

  if [ ! -f "${SCHEMA}" ]; then
    echo "arclight-core: expected a schema at ${SCHEMA} but found none" >&2
    exit 1
  fi

  # --- the is_creator field -------------------------------------------------
  # Arcflow marks its creator documents with a boolean `is_creator` so they can
  # be told apart from collections. It is not an Arclight field, and it does
  # not match any of Arclight's dynamic field patterns (*_ssim, *_tesim and so
  # on), so without it indexing creators fails with:
  #
  #   ERROR: [doc=creator_corporate_entities_584] unknown field 'is_creator'
  #
  # Arcflow's README says to add this through Solr's Schema API. That cannot
  # work against this configset: Arclight's solrconfig.xml sets
  #
  #   <schemaFactory class="ClassicIndexSchemaFactory"/>
  #
  # which makes the schema read-only at runtime -- the Schema API answers 400.
  # The field has to be present in schema.xml before the core is loaded, which
  # is exactly where we are now.
  if grep -q 'name="is_creator"' "${SCHEMA}"; then
    echo "arclight-core: is_creator already present in ${CORE}"
    exit 0
  fi

  # Insert before the first <field ...> declaration, so the new field lands
  # inside whatever element holds the others. Falling back to </schema> covers
  # a configset with no explicit fields at all.
  #
  # awk rather than an XML library because this image has no Python and no
  # xmlstarlet; the insertion is a whole-line one, so no parsing is needed.
  awk '
    BEGIN { done = 0 }
    !done && /<field[ \t]/ {
      print "   <!-- Added at container startup by"
      print "        docker/solr/arclight-core.sh. Arcflow marks creator"
      print "        documents with this so they can be told apart from"
      print "        collections. It is not part of stock Arclight, and because"
      print "        this configset uses ClassicIndexSchemaFactory it cannot be"
      print "        added through the Schema API at runtime. -->"
      print "   <field name=\"is_creator\" type=\"boolean\" indexed=\"true\" stored=\"true\" multiValued=\"false\" />"
      done = 1
    }
    !done && /<\/schema>/ {
      print "   <field name=\"is_creator\" type=\"boolean\" indexed=\"true\" stored=\"true\" multiValued=\"false\" />"
      done = 1
    }
    { print }
    END { if (!done) exit 3 }
  ' "${SCHEMA}" > "${SCHEMA}.new"

  # Only swap the file in once we know the rewrite produced something sane. A
  # truncated or fieldless schema would fail at core load with an error that
  # points at Solr rather than at this script.
  if [ ! -s "${SCHEMA}.new" ] || ! grep -q 'name="is_creator"' "${SCHEMA}.new"; then
    rm -f "${SCHEMA}.new"
    echo "arclight-core: could not add is_creator to ${SCHEMA}; leaving it unchanged" >&2
    exit 1
  fi

  mv "${SCHEMA}.new" "${SCHEMA}"
  echo "arclight-core: added is_creator to ${CORE}"
)

# The subshell's status, not the script's: without this the `set -e` in
# run-initdb would kill ArchivesSpace's Solr over an Arclight problem.
if [ $? -ne 0 ]; then
  echo "arclight-core: the Arclight core was NOT set up. ArchivesSpace's own" >&2
  echo "arclight-core: core is unaffected and Solr is starting normally." >&2
fi

true
