# Solr for both ArchivesSpace and Arclight.
#
# This is deliberately a near-copy of ArchivesSpace's own solr/Dockerfile:
#
#   FROM solr:9.4.1
#   ENV SOLR_MODULES=analysis-extras
#   COPY * $ARCHIVESSPACE_CONFIGSET_PATH/
#
# That is the whole of it. The archivesspace/solr image is stock Solr plus one
# environment variable and about 40kB of XML -- so there is no need to run
# their image to get their configset, and one good reason not to: they publish
# linux/amd64 only, while the stock solr image is published for arm64 as well.
# Building from stock means Solr runs natively on Apple Silicon rather than
# under emulation, which matters for the sustained work of indexing.
#
# The configset is fetched from the ArchivesSpace repository at the tag
# matching ASPACE_VERSION, so it stays locked to the application version. Those
# files are byte-identical to the ones baked into archivesspace/solr.
#
# That is not a nicety. ArchivesSpace SHA-256s the schema.xml its core serves
# and compares it against the copy bundled in the application, refusing to
# start on a mismatch (AppConfig[:solr_verify_checksums]). Any edit to the
# fetched schema, even whitespace, will stop the backend booting.

ARG SOLR_VERSION=9.4.1
FROM solr:${SOLR_VERSION}

# Which ArchivesSpace release's configset to install. Must match the
# archivesspace image the stack runs, for the checksum reason above.
ARG ASPACE_VERSION=4.1.1

# ArchivesSpace's schema uses ICU folding, whose analysers live in the
# analysis-extras module. The jars ship in the stock v9 image but are not on
# the classpath until the module is named here -- without this the core fails
# to load with a ClassNotFoundException for ICUFoldingFilterFactory.
ENV SOLR_MODULES=analysis-extras

USER root

# The files ArchivesSpace's own Dockerfile copies in with `COPY *`. Listed
# explicitly because we are pulling them over the network rather than from a
# checkout, so there is nothing to glob; if a future ArchivesSpace release adds
# a configset file, add it here too. curl -f makes a missing file a build
# failure rather than a core that loads with a silently incomplete config.
RUN set -eux; \
    conf=/opt/solr/server/solr/configsets/archivesspace/conf; \
    mkdir -p "$conf"; \
    for file in schema.xml solrconfig.xml stopwords.txt synonyms.txt; do \
      curl -fsSL \
        -o "$conf/$file" \
        "https://raw.githubusercontent.com/archivesspace/archivesspace/v${ASPACE_VERSION}/solr/$file"; \
    done; \
    # A 404 page saved as schema.xml would still be a file, so check we got
    # XML. Cheap, and the failure it prevents is an obscure one.
    grep -q '<schema' "$conf/schema.xml"; \
    grep -q '<config' "$conf/solrconfig.xml"; \
    chown -R solr:solr /opt/solr/server/solr/configsets/archivesspace

USER solr
