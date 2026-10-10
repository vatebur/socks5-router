#!/usr/bin/env bash
# Exercise destructive cleanup in an isolated tree with fake service/accounts.
set -Eeuo pipefail
TEST_RESOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# An optional baseline script lets this test reproduce the pre-fix failure.
# shellcheck disable=SC1090
source "${1:-$TEST_RESOURCE/socks5.sh}"
TEST_STAGE=$(mktemp -d /tmp/socks5-uninstall-test.XXXXXX)
trap 'rm -rf -- "$TEST_STAGE"' EXIT
ROOT_PREFIX="$TEST_STAGE/root"
BASE="$ROOT_PREFIX/etc/socks5-router"
LIB="$ROOT_PREFIX/usr/local/lib/socks5-router"
STATE_FILE="$BASE/state.json"
CONFIG_FILE="$BASE/config.json"
UNIT_FILE="$ROOT_PREFIX/etc/systemd/system/$SERVICE"
COMMAND_FILE="$ROOT_PREFIX/usr/local/bin/socks5-router"
LOCK_FILE="$ROOT_PREFIX/run/socks5-router.lock"

service_ctl() {
    case $1 in
        show)
            (( ! FAIL_SHOW )) || return 1
            if [[ -f $UNIT_FILE ]]; then printf 'loaded\n'; else printf 'not-found\n'; fi;;
        stop) (( ! FAIL_STOP )) || return 1; RUNNING=0; FAILED=0;;
        disable)
            (( ! FAIL_DISABLE )) || return 1
            ENABLED=0
            # systemd can discard a stopped unit after disable reloads it.
            LOADED=0;;
        is-failed) (( LOADED )) || return 4; (( FAILED ));;
        reset-failed)
            RESET_CALLS=$((RESET_CALLS+1))
            (( LOADED )) || { printf 'Unit socks5-router.service not loaded.\n' >&2; return 1; }
            FAILED=0;;
        daemon-reload) return 0;;
        *) printf 'Unexpected systemctl call: %s\n' "$*" >&2; return 1;;
    esac
}
id() {
    if [[ ${1:-} == -u && ${2:-} == "$ACCOUNT" ]]; then
        (( USER_EXISTS )) || return 1
        printf '987\n'
    else command id "$@"; fi
}
getent() {
    if [[ $1 == group && $2 == "$ACCOUNT" ]]; then
        (( GROUP_EXISTS )) || return 2
        printf '%s:x:987:\n' "$ACCOUNT"
    else command getent "$@"; fi
}
userdel() {
    [[ $1 == "$ACCOUNT" ]] && (( ! FAIL_USERDEL )) || return 1
    USER_EXISTS=0
    if (( AUTO_REMOVE_GROUP )); then GROUP_EXISTS=0; fi
}
groupdel() { [[ $1 == "$ACCOUNT" ]] || return 1; GROUP_EXISTS=0; }

fixture() {
    RUNNING=1 ENABLED=1 LOADED=1 FAILED=0 RESET_CALLS=0
    USER_EXISTS=1 GROUP_EXISTS=1 AUTO_REMOVE_GROUP=0
    FAIL_SHOW=0 FAIL_STOP=0 FAIL_DISABLE=0 FAIL_USERDEL=0
    mkdir -p "$BASE" "$LIB" "$(dirname -- "$COMMAND_FILE")" \
        "$(dirname -- "$UNIT_FILE")/multi-user.target.wants" "$ROOT_PREFIX/run"
    printf 'fixture credentials\n' > "$STATE_FILE"
    touch "$CONFIG_FILE" "$UNIT_FILE" "$LIB/xray" "$COMMAND_FILE" "$LOCK_FILE"
    ln -sf "$UNIT_FILE" "$(dirname -- "$UNIT_FILE")/multi-user.target.wants/$SERVICE"
}
assert_removed() {
    [[ $UNINSTALL_COMPLETED == 1 && $RUNNING == 0 && $ENABLED == 0 ]]
    [[ $USER_EXISTS == 0 && $GROUP_EXISTS == 0 ]]
    [[ ! -e $BASE && ! -e $LIB && ! -e $UNIT_FILE && ! -e $COMMAND_FILE && ! -e $LOCK_FILE ]]
    [[ ! -L $(dirname -- "$UNIT_FILE")/multi-user.target.wants/$SERVICE ]]
}

fixture
uninstall_service <<< cancel > "$TEST_STAGE/cancel.log" 2>&1
[[ $UNINSTALL_COMPLETED == 0 && -f $STATE_FILE && $RUNNING == 1 && $USER_EXISTS == 1 ]]
for flag in FAIL_SHOW FAIL_STOP FAIL_DISABLE FAIL_USERDEL; do
    printf -v "$flag" '%s' 1
    if uninstall_service <<< DELETE > "$TEST_STAGE/$flag.log" 2>&1; then exit 1; fi
    [[ $UNINSTALL_COMPLETED == 0 && -f $STATE_FILE && $USER_EXISTS == 1 ]]
    printf -v "$flag" '%s' 0
done
printf 'PASS cancellation and real service/account errors preserve configuration\n'

fixture
uninstall_service <<< DELETE > "$TEST_STAGE/uninstall.log" 2>&1 || {
    cat "$TEST_STAGE/uninstall.log" >&2
    exit 1
}
assert_removed
[[ $LOADED == 0 && $RESET_CALLS == 0 ]]
printf 'PASS uninstall completes when disable unloads the unit; all project files and accounts removed\n'

fixture
AUTO_REMOVE_GROUP=1
uninstall_service <<< DELETE > "$TEST_STAGE/auto-group.log" 2>&1
assert_removed
printf 'PASS account deletion that also removes the private group\n'

fixture
rm -f -- "$UNIT_FILE"
LOADED=0 RUNNING=0 ENABLED=0
uninstall_service <<< DELETE > "$TEST_STAGE/partial.log" 2>&1
assert_removed
uninstall_service <<< DELETE > "$TEST_STAGE/repeated.log" 2>&1
assert_removed
printf 'PASS partial installation cleanup and repeated uninstall\n'
