#!/usr/bin/env bash
#
# Follow logs.
#
#   ./scripts/logs.sh                   # ArchivesSpace
#   ./scripts/logs.sh solr              # a named service
#   ./scripts/logs.sh --jobs            # just background job output
#   ./scripts/logs.sh --errors          # just errors, with their stack traces
#   ./scripts/logs.sh --errors --since 10m
#
# --jobs is the one you want when watching an Alma audit run.
#
# --errors is the one you want when a page has returned 500. ArchivesSpace runs
# Rails in production mode, so the browser only shows a generic apology page and
# the actual exception goes to the log -- where the indexer buries it under a
# continuous stream of DEBUG lines. This flag pulls out the exception and the
# frames underneath it.
#
# Options:
#   --since <duration>   only logs newer than this (e.g. 10m, 1h)
#   --tail <n>           start from the last n lines
#   --context <n>        lines of trace to show after each error (default: 25)
#   --no-follow          print and exit instead of tailing

set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE=""
MODE="plain"
SINCE=""
TAIL=""
CONTEXT=25
FOLLOW=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)      MODE="jobs" ;;
    --errors|-e) MODE="errors" ;;
    --since)     SINCE="${2:-}"; shift ;;
    --since=*)   SINCE="${1#*=}" ;;
    --tail)      TAIL="${2:-}"; shift ;;
    --tail=*)    TAIL="${1#*=}" ;;
    --context)   CONTEXT="${2:-}"; shift ;;
    --context=*) CONTEXT="${1#*=}" ;;
    --no-follow) FOLLOW=0 ;;
    -h|--help)   sed -n '2,25p' "$0" | sed 's/^#//;s/^ //'; exit 0 ;;
    -*)          echo "logs.sh: unknown option: $1" >&2; exit 2 ;;
    *)           SERVICE="$1" ;;
  esac
  shift
done

SERVICE="${SERVICE:-archivesspace}"

ARGS=(logs "$SERVICE")
[[ "$FOLLOW" == "1" ]] && ARGS+=(-f)
[[ -n "$SINCE" ]] && ARGS+=(--since "$SINCE")
[[ -n "$TAIL" ]] && ARGS+=(--tail "$TAIL")

case "$MODE" in
  jobs)
    docker compose "${ARGS[@]}" | grep --line-buffered -Ei 'job|alma|audit|index'
    ;;

  errors)
    # Lines that are noise rather than a problem. JRuby re-warns about
    # already-loaded constants on every boot, and the Rack one contains the
    # literal string "RACK_ERRORS", so it matches any naive error filter.
    # The indexer logs a round every 30s at INFO, which is the flood that makes
    # a real error impossible to spot, so drop those too.
    NOISE='already initialized constant|warning: |Rack::RACK_ERRORS|DEBUG --|Indexer \[|Index round'

    # An error, or the start of one. "Completed 5xx" is what ArchivesSpace
    # logs immediately before the exception and its backtrace, so matching it
    # is what makes the trailing context worth having. 403 and 404 are ordinary
    # ArchivesSpace responses (denied, not found) and are deliberately not here.
    ERRORS='FATAL|ERROR --|Completed 5[0-9][0-9]|[A-Za-z:]*(Error|Exception) \(|undefined method|undefined local variable|uninitialized constant|Missing (partial|template)|Template substitution|No such file'

    # Strip the noise first: filtering afterwards would punch holes in the
    # context blocks and split the stack traces up.
    #
    # grep exits 1 when nothing matched, which under `set -e` would make a
    # clean log look like a failure, so absorb that.
    docker compose "${ARGS[@]}" 2>&1 \
      | grep --line-buffered -Ev "$NOISE" \
      | grep --line-buffered -A "$CONTEXT" -E "$ERRORS" || true
    ;;

  *)
    docker compose "${ARGS[@]}"
    ;;
esac
