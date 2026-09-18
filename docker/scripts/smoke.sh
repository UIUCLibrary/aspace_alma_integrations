#!/usr/bin/env bash
#
# smoke.sh -- load every page this plugin adds and fail if any of them errors.
#
# This exists because the RSpec suite covers pure Ruby logic only: it never
# renders a view or exercises a controller. A view that calls a method
# ArchivesSpace does not have is therefore invisible to `rspec` and shows up
# as a 500 in somebody's browser. This script closes that gap.
#
# It drives HTTP from *inside* the archivesspace container rather than from
# the host, so it does not depend on published ports working.
#
# Usage:
#   scripts/smoke.sh              # check every plugin page
#   scripts/smoke.sh --verbose    # also print the offending response body
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^#//;s/^ //'
      exit 0
      ;;
    *) echo "smoke.sh: unknown option: $arg" >&2; exit 2 ;;
  esac
done

USER_NAME="${ASPACE_ADMIN_USER:-admin}"
PASS="${ASPACE_ADMIN_PASSWORD:-admin}"

if ! docker compose ps --status running --services 2>/dev/null | grep -qx archivesspace; then
  echo "smoke.sh: the archivesspace service is not running. Start it with scripts/up.sh" >&2
  exit 1
fi

# Pages the plugin adds. Each is "<label>|<path>".
#
# The jobs/new entries matter as much as the plugin's own controllers: that is
# where ArchivesSpace renders our _form partials, so a broken job form only
# shows up here.
PAGES="
audit report list|/plugins/alma_audit_reports
alma integrations|/plugins/alma_integrations
audit job form|/jobs/new?job_type=alma_audit_job
bulk update job form|/jobs/new?job_type=alma_bulk_update_job
job list|/jobs
"

# Strings that mean the page blew up. ArchivesSpace runs Rails in production
# mode, so a 500 renders a generic apology page and the real error only
# reaches the log -- hence checking both the status code and the body.
MARKERS='Template::Error|NoMethodError|NameError|undefined method|undefined local variable|Missing partial|Missing template|uninitialized constant|ActionView::|ActionController::|translation missing'

echo "==> Logging in to ArchivesSpace as ${USER_NAME}"

RESULT=$(docker compose exec -T \
  -e SMOKE_USER="$USER_NAME" -e SMOKE_PASS="$PASS" \
  -e SMOKE_PAGES="$PAGES" -e SMOKE_MARKERS="$MARKERS" -e SMOKE_VERBOSE="$VERBOSE" \
  archivesspace sh -s <<'INNER'
set -u
cd /tmp || exit 1
rm -f smoke_cookies.txt smoke_body.html smoke_login.html

wget -q -O smoke_login.html --keep-session-cookies --save-cookies smoke_cookies.txt \
  http://localhost:8080/ || { echo "FATAL|could not reach the frontend at all"; exit 1; }

TOKEN=$(grep -o 'name="authenticity_token" value="[^"]*"' smoke_login.html \
        | head -1 | sed 's/.*value="//;s/"$//')
if [ -z "$TOKEN" ]; then
  echo "FATAL|no authenticity_token on the login page -- is this really ArchivesSpace?"
  exit 1
fi

# The CSRF token is base64 and routinely contains +, / and =. Posted raw they
# are read as form syntax ("+" becomes a space) and Rails rejects the request
# with 422 Unprocessable Entity, so percent-encode them.
TOKEN=$(printf '%s' "$TOKEN" | sed 's/%/%25/g; s/+/%2B/g; s|/|%2F|g; s/=/%3D/g')

wget -q -O smoke_after_login.html \
  --keep-session-cookies --load-cookies smoke_cookies.txt --save-cookies smoke_cookies.txt \
  --post-data "authenticity_token=${TOKEN}&username=${SMOKE_USER}&password=${SMOKE_PASS}" \
  http://localhost:8080/login

# The login endpoint is AJAX: on success it returns the session as JSON
# rather than redirecting to a page, so look for the session payload.
if ! grep -q '"session"' smoke_after_login.html 2>/dev/null; then
  echo "FATAL|login as ${SMOKE_USER} was rejected"
  exit 1
fi

echo "OK|logged in"

# ArchivesSpace resolves most job and record URLs through a /repositories/:repo_id
# template, so with no repository selected in the session those pages raise
# "Template substitution was incomplete" and return 500. That is an artefact of
# an empty test stack, not a plugin fault, so select a repository before
# checking any pages -- otherwise the run is all false failures.
# Repository 1 is the global/system repository and cannot be selected, so take
# the lowest real repository id off the repositories listing.
wget -q -O smoke_repos.html --load-cookies smoke_cookies.txt \
  http://localhost:8080/repositories 2>/dev/null
REPO_ID=$(grep -o '/repositories/[0-9][0-9]*' smoke_repos.html 2>/dev/null \
          | sed 's|.*/||' | grep -vx 1 | sort -n | uniq | head -1)

if [ -n "$REPO_ID" ]; then
  # repositories#select is POST-only and CSRF-protected, so mint a fresh token.
  wget -q -O smoke_repo.html --load-cookies smoke_cookies.txt --save-cookies smoke_cookies.txt \
    --keep-session-cookies http://localhost:8080/ 2>/dev/null
  RTOKEN=$(grep -o 'name="authenticity_token" value="[^"]*"' smoke_repo.html \
           | head -1 | sed 's/.*value="//;s/"$//' \
           | sed 's/%/%25/g; s/+/%2B/g; s|/|%2F|g; s/=/%3D/g')
  wget -q -O /dev/null --load-cookies smoke_cookies.txt --save-cookies smoke_cookies.txt \
    --keep-session-cookies \
    --post-data "authenticity_token=${RTOKEN}&repo_id=${REPO_ID}" \
    http://localhost:8080/repositories/select 2>/dev/null
  echo "OK|selected repository ${REPO_ID}"
else
  echo "OK|no repository exists -- create one, or job pages will fail spuriously"
fi

printf '%s
' "$SMOKE_PAGES" | while IFS='|' read -r LABEL PATH_; do
  [ -z "${LABEL:-}" ] && continue
  [ -z "${PATH_:-}" ] && continue

  CODE=$(wget -S -O smoke_body.html --load-cookies smoke_cookies.txt \
           "http://localhost:8080${PATH_}" 2>&1 \
         | awk '/^  HTTP\//{c=$2} END{print c}')
  CODE="${CODE:-000}"

  HITS=$(grep -oE "$SMOKE_MARKERS" smoke_body.html 2>/dev/null | sort -u | tr '
' ' ')

  if [ "$CODE" != "200" ]; then
    echo "FAIL|${LABEL}|${PATH_}|HTTP ${CODE}|${HITS}"
  elif [ -n "$HITS" ]; then
    echo "FAIL|${LABEL}|${PATH_}|HTTP 200 but body contains: ${HITS}|"
  else
    echo "PASS|${LABEL}|${PATH_}|HTTP 200|"
  fi

  if [ "$SMOKE_VERBOSE" = "1" ]; then
    echo "BODY|${LABEL}"
    sed -n '1,400p' smoke_body.html
  fi
done
INNER
)

echo "$RESULT" | grep -v '^BODY|' | while IFS='|' read -r STATUS A B C D; do
  case "$STATUS" in
    OK)    echo "    $A" ;;
    PASS)  printf '    \033[32mok\033[0m   %-24s %s\n' "$A" "$C" ;;
    FAIL)  printf '    \033[31mFAIL\033[0m %-24s %s %s\n' "$A" "$C" "$D" ;;
    FATAL) echo "smoke.sh: $A" >&2 ;;
  esac
done

if [ "$VERBOSE" = "1" ]; then
  echo "$RESULT" | sed -n '/^BODY|/,$p'
fi

if echo "$RESULT" | grep -q '^FATAL|'; then
  exit 1
fi

if echo "$RESULT" | grep -q '^FAIL|'; then
  echo
  echo "One or more plugin pages failed to render."
  echo "For the underlying stack trace:  scripts/logs.sh --errors"
  exit 1
fi

echo
echo "All plugin pages rendered."
