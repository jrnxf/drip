# Sourced by the scripts that show real drip cards on screen (mac-check.sh, mac-e2e.sh): they run
# only where DRIP_LIVE_CHECKS=isolated says the Mac is one nobody works at, such as the live job in
# .github/workflows/ci.yml or a macOS VM. On a Mac in use, their cards come up at the notch beside
# the person's own, from a drip with its own queue and state, so the person's history misses cards,
# a "missed N drips" notice can follow on wake, and the cards ignore their drip pause.
#
#   live_guard NAME   exits 2 with why, unless DRIP_LIVE_CHECKS=isolated
live_guard() {
    [ "${DRIP_LIVE_CHECKS:-}" = isolated ] && return 0
    cat >&2 <<MESSAGE
$1: not run. It shows real drip cards on this screen, from a drip with its own queue and state,
so it runs only on a Mac nobody works at, such as a CI runner or a macOS VM: there, set
DRIP_LIVE_CHECKS=isolated. The live job in .github/workflows/ci.yml runs mac-e2e.sh on every push.
The unit and snapshot tests need no screen: run swift test.
MESSAGE
    exit 2
}
