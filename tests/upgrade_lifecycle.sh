#!/usr/bin/env bash
# Upgrade real manager files in an isolated tree; never touch host services.
set -Eeuo pipefail
TEST_RESOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$TEST_RESOURCE/socks5.sh"
TEST_STAGE=$(mktemp -d /tmp/socks5-upgrade-test.XXXXXX)
trap 'rm -rf -- "$TEST_STAGE"' EXIT
ROOT_PREFIX="$TEST_STAGE/root"
BASE="$ROOT_PREFIX/etc/socks5-router"
LIB="$ROOT_PREFIX/usr/local/lib/socks5-router"
STATE_FILE="$BASE/state.json"
CONFIG_FILE="$BASE/config.json"
UNIT_FILE="$ROOT_PREFIX/etc/systemd/system/$SERVICE"
COMMAND_FILE="$ROOT_PREFIX/usr/local/bin/socks5-router"
CONFIG_GROUP=$(id -gn)
mkdir -p "$BASE" "$LIB" "$(dirname -- "$UNIT_FILE")"
XRAY=${1:-}
ORIGINAL_VERSION=$VERSION
SERVICE_CALLS=0 DOWNLOAD_FAIL=0
service_ctl() { SERVICE_CALLS=$((SERVICE_CALLS+1)); return 1; }
download_release() {
    (( ! DOWNLOAD_FAIL )) || return 1
    cp -a "$TEST_STAGE/candidate" "$1/socks5-router"
}
candidate() {
    rm -rf -- "$TEST_STAGE/candidate"
    mkdir -p "$TEST_STAGE/candidate/lib" "$TEST_STAGE/candidate/templates"
    for path in socks5.sh install.sh lib/config.sh templates/xray.json templates/render.jq; do
        cp "$TEST_RESOURCE/$path" "$TEST_STAGE/candidate/$path"
    done
    sed -i "s/^VERSION=.*/VERSION=$1/" "$TEST_STAGE/candidate/socks5.sh"
}
manager_snapshot() {
    sha256sum "$LIB/socks5.sh" "$LIB/install.sh" "$LIB/lib/config.sh" \
        "$LIB/templates/xray.json" "$LIB/templates/render.jq" "$COMMAND_FILE"
    stat -c '%a %u %g' "$LIB/socks5.sh" "$LIB/install.sh" "$LIB/lib/config.sh" \
        "$LIB/templates/xray.json" "$LIB/templates/render.jq" "$COMMAND_FILE"
}
runtime_snapshot() { sha256sum "$STATE_FILE" "$CONFIG_FILE" "$UNIT_FILE"; }

version_newer 1.0.0 0.99.99
version_newer 0.10.0 0.9.99
version_newer 0.4.10 0.4.9
if version_newer 0.4.0 0.4.0 || version_newer 0.3.9 0.4.0 || version_newer invalid 0.4.0; then exit 1; fi
printf 'PASS numeric version ordering, equality, older and invalid versions\n'

install_manager
candidate "$ORIGINAL_VERSION"
VERSION=0.0.0
upgrade_manager > "$TEST_STAGE/no-state.log" 2>&1
[[ $UPGRADE_COMPLETED == 1 && $SERVICE_CALLS == 0 && ! -e $STATE_FILE ]]
[[ $("$COMMAND_FILE" --version) == "$ORIGINAL_VERSION" ]]
printf 'PASS upgrade without configured service installs a working menu command\n'
VERSION=$ORIGINAL_VERSION
before=$(manager_snapshot)
upgrade_manager > "$TEST_STAGE/same.log" 2>&1
[[ $UPGRADE_COMPLETED == 0 && $(manager_snapshot) == "$before" ]]
candidate 0.0.0
upgrade_manager > "$TEST_STAGE/older.log" 2>&1
[[ $UPGRADE_COMPLETED == 0 && $(manager_snapshot) == "$before" ]]
candidate invalid
if upgrade_manager > "$TEST_STAGE/invalid.log" 2>&1; then exit 1; fi
[[ $UPGRADE_COMPLETED == 0 && $(manager_snapshot) == "$before" ]]
candidate "$ORIGINAL_VERSION"
DOWNLOAD_FAIL=1 VERSION=0.0.0
if upgrade_manager > "$TEST_STAGE/download.log" 2>&1; then exit 1; fi
[[ $UPGRADE_COMPLETED == 0 && $(manager_snapshot) == "$before" ]]
DOWNLOAD_FAIL=0
printf 'PASS same/older versions, malformed version and download failure retain installed files\n'

if [[ -n $XRAY ]]; then
    normalize_state "$TEST_RESOURCE/examples/server-b.json" > "$STATE_FILE"
    render_config "$STATE_FILE" > "$CONFIG_FILE"
    render_unit > "$UNIT_FILE"
    chmod 600 "$STATE_FILE"
    chmod 640 "$CONFIG_FILE"
    runtime_before=$(runtime_snapshot)
    upgrade_manager > "$TEST_STAGE/configured.log" 2>&1
    [[ $UPGRADE_COMPLETED == 1 && $SERVICE_CALLS == 0 && $(runtime_snapshot) == "$runtime_before" ]]
    before=$(manager_snapshot)
    VERSION=0.0.0
    (
        XRAY=/bin/false
        if upgrade_manager > "$TEST_STAGE/core.log" 2>&1; then exit 1; fi
        [[ $UPGRADE_COMPLETED == 0 && $(manager_snapshot) == "$before" ]]
    )
    jq '.log.loglevel="error"' "$TEST_STAGE/candidate/templates/xray.json" > "$TEST_STAGE/incompatible.json"
    cp "$TEST_STAGE/incompatible.json" "$TEST_STAGE/candidate/templates/xray.json"
    if upgrade_manager > "$TEST_STAGE/incompatible.log" 2>&1; then exit 1; fi
    [[ $UPGRADE_COMPLETED == 0 && $(manager_snapshot) == "$before" && $(runtime_snapshot) == "$runtime_before" ]]
    candidate "$ORIGINAL_VERSION"
    printf 'PASS real Xray compatibility check preserves state, credentials, config and service state\n'
fi

before=$(manager_snapshot)
(
    # replace_manager invokes this override during the simulated upgrade.
    # shellcheck disable=SC2329
    install_manager() { printf 'partial upgrade\n' > "$LIB/socks5.sh"; return 1; }
    if upgrade_manager > "$TEST_STAGE/rollback.log" 2>&1; then exit 1; fi
    [[ $UPGRADE_COMPLETED == 0 && $(manager_snapshot) == "$before" ]]
    [[ $SERVICE_CALLS == 0 ]]
)
[[ -z $CURRENT_STAGE ]]
printf 'PASS partial manager installation restores file contents and permissions\n'
