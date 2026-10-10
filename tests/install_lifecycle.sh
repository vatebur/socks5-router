#!/usr/bin/env bash
# Test first-run persistence and deployment without changing host services/users.
set -Eeuo pipefail
TEST_RESOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$TEST_RESOURCE/socks5.sh"
TEST_STAGE=$(mktemp -d /tmp/socks5-install-test.XXXXXX)
trap 'rm -rf -- "$TEST_STAGE"' EXIT
ROOT_PREFIX="$TEST_STAGE/root with spaces"
BASE="$ROOT_PREFIX/etc/socks5-router"
LIB="$ROOT_PREFIX/usr/local/lib/socks5-router"
STATE_FILE="$BASE/state.json"
CONFIG_FILE="$BASE/config.json"
XRAY="$LIB/xray"
UNIT_FILE="$ROOT_PREFIX/etc/systemd/system/$SERVICE"
COMMAND_FILE="$ROOT_PREFIX/usr/local/bin/socks5-router"
LOCK_FILE="$ROOT_PREFIX/run/socks5-router.lock"
CONFIG_GROUP=$(id -gn)
mkdir -p "$(dirname -- "$LOCK_FILE")"

# Host dependency/account/systemd operations are intentionally replaced. The
# manager installation, ZIP verification, rendering and Xray validation are real.
ensure_dependencies() { return 0; }
prepare_dirs() {
    install -d -m 750 "$BASE"
    install -d -m 755 "$LIB" "$(dirname -- "$UNIT_FILE")"
}
RUNNING=0 ENABLED=0
service_ctl() {
    case $1 in
        is-active) (( RUNNING ));;
        is-enabled) (( ENABLED ));;
        restart) RUNNING=1;;
        stop) RUNNING=0;;
        enable) ENABLED=1;;
        disable) ENABLED=0;;
        *) return 0;;
    esac
}
wait_started() { (( RUNNING )); }
port_free() { return 0; }

(
    main menu <<< 0 > "$TEST_STAGE/menu.log" 2>&1
)
[[ -x $COMMAND_FILE && ! -e $STATE_FILE && ! -e $XRAY ]]
[[ $("$COMMAND_FILE" --version) == "$VERSION" ]]
printf 'PASS first menu installs a working command without a configured service\n'

form_new
form_json inbound_enabled true
form_set listen ::
form_json port 21080
form_set username regression-user
form_set password regression-password
printf '%s\n' "$FORM_STATE" > "$TEST_STAGE/inbound.json"
(
    install_core() { return 1; }
    if deploy "$TEST_STAGE/inbound.json" > "$TEST_STAGE/failure.log" 2>&1; then exit 1; fi
    [[ -x $COMMAND_FILE && ! -e $STATE_FILE ]]
    [[ $("$COMMAND_FILE" --version) == "$VERSION" ]]
    rg -q '安装 Xray 核心失败' "$TEST_STAGE/failure.log"
)
printf 'PASS core installation failure retains the menu command and reports its stage\n'

if [[ -n ${1:-} ]]; then
    deploy "$TEST_STAGE/inbound.json" "$1" > "$TEST_STAGE/deploy.log" 2>&1
    [[ $RUNNING == 1 && $ENABLED == 1 ]]
    jq -e '.inbound_enabled and .port==21080' "$STATE_FILE" >/dev/null
    "$XRAY" run -test -config "$CONFIG_FILE" > "$TEST_STAGE/xray.log" 2>&1
    [[ $(stat -c %a "$STATE_FILE") == 600 && $(stat -c %a "$CONFIG_FILE") == 640 ]]
    printf 'PASS fresh inbound deployment with verified offline core and real Xray validation\n'
fi
