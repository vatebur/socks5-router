#!/usr/bin/env bash
# Runtime prerequisites, installation paths and manager file installation.

require_root() { (( EUID == 0 )) || { error '此操作需要 root，请使用 sudo bash socks5.sh。'; return 1; }; }

service_ctl() { systemctl "$@"; }

service_active() { service_ctl is-active --quiet "$SERVICE"; }

reset_failed_service() {
    # A newly written unit may not be loaded yet. Only failed units need their
    # failure state/start limit cleared; restart will load a fresh unit itself.
    if service_ctl is-failed --quiet "$SERVICE"; then
        service_ctl reset-failed "$SERVICE" || return 1
    fi
    return 0
}

require_state() {
    [[ -f $STATE_FILE ]] || {
        warn '尚未配置 SOCKS5，请先选择「1. SOCKS5 部署」安装入站或出站。'
        return 1
    }
}

inbound_installed() { [[ -f $STATE_FILE ]] && jq -e '.schema==1 or .inbound_enabled==true' "$STATE_FILE" >/dev/null; }

outbound_installed() { [[ -f $STATE_FILE ]] && jq -e '.upstream!=null' "$STATE_FILE" >/dev/null; }

require_inbound() {
    require_state || return 1
    inbound_installed || { warn '尚未安装 SOCKS5 入站，请先通过部署菜单安装入站。'; return 1; }
}

require_outbound() {
    require_state || return 1
    outbound_installed || { warn '尚未安装 SOCKS5 出站，请先通过部署菜单安装出站及分流。'; return 1; }
}

require_runtime() {
    require_state || return 1
    [[ -f $CONFIG_FILE && -f $UNIT_FILE && -x $XRAY ]] || {
        error '运行配置、服务文件或 Xray 核心不完整，请检查安装目录。'; return 1;
    }
}

ensure_jq() { ensure_tools jq; }

ensure_dependencies() {
    ensure_tools jq curl unzip tar ss flock timeout sha256sum od dd install stat useradd userdel groupdel getent ca-certificates
}

prepare_dirs() {
    local uid
    if uid=$(id -u "$ACCOUNT" 2>/dev/null); then
        (( uid != 0 )) || { error '专用服务账号意外指向 root。'; return 1; }
    else
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "$ACCOUNT" || return 1
    fi
    getent group "$CONFIG_GROUP" >/dev/null || { error '专用服务账号的同名组不存在。'; return 1; }
    install -d -m 750 -g "$CONFIG_GROUP" "$BASE" || return 1
    install -d -m 755 "$LIB" "$(dirname -- "$UNIT_FILE")" "$(dirname -- "$COMMAND_FILE")"
}

install_manager() {
    local path
    install -d -m 755 "$LIB/lib" "$LIB/templates" "$(dirname -- "$COMMAND_FILE")" || return 1
    for path in "${MANAGER_FILES[@]}"; do
        if [[ "$RESOURCE_DIR/$path" != "$LIB/$path" ]]; then
            install -m 644 -- "$RESOURCE_DIR/$path" "$LIB/$path" || return 1
        fi
    done
    chmod 755 "$LIB/socks5.sh" || return 1
    local wrapper
    wrapper=$(mktemp "$(dirname -- "$COMMAND_FILE")/.socks5-router.XXXXXX") || return 1
    printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$LIB/socks5.sh" > "$wrapper" || { rm -f -- "$wrapper"; return 1; }
    if ! { chmod 755 "$wrapper" && mv -f -- "$wrapper" "$COMMAND_FILE"; }; then
        rm -f -- "$wrapper"; return 1
    fi
    return 0
}
