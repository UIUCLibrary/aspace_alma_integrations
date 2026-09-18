#!/usr/bin/env bash
#
# Run the plugin's unit specs on the JRuby that ArchivesSpace actually uses.
#
#   ./scripts/spec.sh                          # the whole suite
#   ./scripts/spec.sh spec/report_writer_spec.rb
#   ./scripts/spec.sh spec/marc_diff_spec.rb -e "ignores 001"
#
# Why this exists, rather than just running rspec on the host:
#
# ArchivesSpace runs on JRuby, and JRuby is stricter than MRI about string
# encodings. JSON.generate raises Encoding::UndefinedConversionError on JRuby
# for a string tagged ASCII-8BIT that holds bytes above 0x7F, where MRI only
# prints a deprecation warning and carries on. A suite that is green on the
# host can therefore still fail in production -- which is exactly what happened
# with the audit report writer. Running the specs here closes that gap.
#
# This does not need the stack to be up; it starts a throwaway container, and
# leaves no trace behind. rspec is fetched into that container each run, which
# costs a few seconds and avoids a cache that can go stale or end up owned by
# the wrong user.

set -euo pipefail
cd "$(dirname "$0")/.."

JRUBY_LIB='/archivesspace/gems/gems/jruby-jars-9.4.8.0/lib'

# The plugin is mounted read-only and copied aside, because rspec writes
# temporary spool files next to the specs and must not touch the working tree.
docker compose run --rm --no-deps \
  -v "$(cd .. && pwd):/plugin:ro" \
  --entrypoint sh archivesspace -c '
set -e

JRUBY_LIB="'"${JRUBY_LIB}"'"
GEM_CACHE=/tmp/rspec-gems

if [ ! -d "${JRUBY_LIB}" ]; then
  # Pinned above so the failure is obvious rather than silently picking another
  # JRuby if the base image is upgraded.
  echo "error: no JRuby at ${JRUBY_LIB}" >&2
  echo "       ArchivesSpace has probably changed version; update scripts/spec.sh." >&2
  ls -d /archivesspace/gems/gems/jruby-jars-* 2>/dev/null >&2 || true
  exit 1
fi

jruby() {
  java -cp "${JRUBY_LIB}/jruby-core-9.4.8.0-complete.jar:${JRUBY_LIB}/jruby-stdlib-9.4.8.0.jar" \
    org.jruby.Main "$@"
}

echo "==> Fetching rspec for JRuby"
# GEM_HOME too, not just --install-dir: rubygems caches the downloaded .gem
# files under GEM_HOME, and the default location is not writable here.
GEM_HOME="${GEM_CACHE}" jruby -S gem install --no-document \
  --install-dir "${GEM_CACHE}" rspec >/dev/null

# The container ships a java-native nokogiri. Its directory has to come first,
# so that it wins over anything in the rspec cache.
export GEM_PATH="/archivesspace/gems:${GEM_CACHE}"

cp -r /plugin /tmp/work
cd /tmp/work

echo "==> Running specs on JRuby"
jruby -e "ARGV.replace(ARGV.empty? ? [\"spec\"] : ARGV); gem \"rspec-core\"; load Gem.bin_path(\"rspec-core\", \"rspec\")" -- "$@"
' -- "$@"
