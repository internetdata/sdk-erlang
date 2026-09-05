#!/bin/bash

# Runs the integration suite against the package as PUBLISHED on hex, which is
# the one thing the unit suite cannot check: that suite tests this working tree,
# so it stays green through an app.src whose modules list forgets half the
# library, a module a consumer cannot resolve, or a tag that never landed.
#
#   ./scripts/run.sh
#
# Two conditions make the run meaningless rather than failing, and each one skips
# with a reason instead:
#
#   1. Nothing published satisfies rebar.config's constraint. Before the first
#      release there is no artifact to test.
#   2. The staging key is missing. The suite skips from inside, so the skip and
#      its reason land in the eunit output rather than in this script's preamble.
#
# A THIRD condition is a failure rather than a skip: the dependency resolving
# from anywhere but hex. A run against local source passes every test and says
# nothing, so rebar.lock is read back AFTER resolution and any other source
# stops the run.
#
# Everything happens inside the official Erlang image, as scripts/test.sh does,
# and only integration/ is mounted. The library source next door is therefore not
# reachable at all, which makes a path dependency impossible rather than merely
# refused.

set -euo pipefail

cd "$(dirname "$0")/.."

OTP_IMAGE="${OTP_IMAGE:-erlang:27}"

function main() {
    local package published

    package="$(inImage 'escript scripts/resolve.escript package')"
    published="$(inImage 'escript scripts/resolve.escript published')"
    if [ -z "$published" ] ; then
        skip "nothing published satisfies rebar.config's ${package} constraint," \
            "so there is no released artifact to test"
        return 0
    fi
    echo "==> ${package} matches published $(echo "$published" | tr '\n' ' ')"

    reportKey
    inImage 'runSuite'
}

# The suite proper, run inside the image. Resolution comes first and its SOURCE
# is checked before a single test runs: `resolve.escript resolved' reads
# rebar.lock, where a hex package locks as `pkg <version>' and anything else
# (git, path, absent) does not.
function runSuite() {
    cat <<'INNER'
        rm -f rebar.lock
        rebar3 get-deps
        resolved="$(escript scripts/resolve.escript resolved)"
        case "$resolved" in
            pkg\ *)
                echo "==> resolved ${resolved} from hex"
                ;;
            *)
                echo "FAILED: the dependency resolved as '${resolved}'," \
                    "so the tests would run against something other than a release" >&2
                exit 1
                ;;
        esac
        rebar3 eunit
INNER
}

# Read only, copied inside, and _build dropped: a stale _build carries beams
# rebar3 keeps rather than rebuilds, and the suite then passes against code that
# is no longer there. Same reasoning as scripts/test.sh.
function inImage() {
    local script
    if [ "$1" = "runSuite" ] ; then
        script="$(runSuite)"
    else
        script="$1"
    fi

    docker run --rm \
        -e HOME=/tmp \
        -e LANG=C.UTF-8 \
        -e "INTERNETDATA_STAGING_URL=${INTERNETDATA_STAGING_URL:-}" \
        -e "INTERNETDATA_STAGING_KEY=${INTERNETDATA_STAGING_KEY:-}" \
        -v "$PWD:/src:ro" \
        "$OTP_IMAGE" sh -euc "
            cp -R /src /w
            cd /w
            rm -rf _build
            ${script}
        "
}

function reportKey() {
    if [ -n "${INTERNETDATA_STAGING_KEY:-}" ] ; then
        echo "==> staging key present"
    else
        notice "INTERNETDATA_STAGING_KEY is not set: every test that needs staging is skipped"
    fi
}

function skip() {
    echo "==> SKIPPED: $*"
    notice "Integration suite skipped: $*"
}

# Surfaced on the workflow run itself, so a skip is visible without opening the
# log and reading to the end of it.
function notice() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ] ; then
        echo "::notice title=Integration::$1"
    fi
}

main "$@"
