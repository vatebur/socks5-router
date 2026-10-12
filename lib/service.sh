#!/usr/bin/env bash
# systemd configuration, transactional configuration application and diagnostics.

render_unit() {
    cat <<'UNIT'
[Unit]
Description=Lightweight SOCKS5 router (Xray)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=socks5-router
Group=socks5-router
ExecStartPre=/usr/local/lib/socks5-router/xray run -test -config /etc/socks5-router/config.json
ExecStart=/usr/local/lib/socks5-router/xray run -config /etc/socks5-router/config.json
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
}

atomic_install() {
    local source=$1 target=$2 mode=$3 group=${4:-root} temporary
    temporary=$(mktemp "$(dirname -- "$target")/.socks5-router.new.XXXXXX") || return 1
    if install -m "$mode" -g "$group" -- "$source" "$temporary" && mv -f -- "$temporary" "$target"; then return 0; fi
    rm -f -- "$temporary"; return 1
}

wait_started() {
    local attempt
    for ((attempt=0;attempt<20;attempt++)); do
        (( APPLY_CANCELLED == 0 )) || return 1
        if service_active; then
            sleep 0.6
            if service_active; then return 0; fi
        fi
        sleep 0.25
    done
    error '服务未能保持运行，请检查 journalctl -u socks5-router。'
}

snapshot_files() {
    local stage=$1 index=0 target
    for target in "$STATE_FILE" "$CONFIG_FILE" "$UNIT_FILE"; do
        if [[ -f $target ]]; then cp -p -- "$target" "$stage/backup.$index" || return 1; fi
        index=$((index+1))
    done
}

restore_files() {
    local stage=$1 index=0 target temporary failed=0
    for target in "$STATE_FILE" "$CONFIG_FILE" "$UNIT_FILE"; do
        if [[ -f $stage/backup.$index ]]; then
            temporary=$(mktemp "$(dirname -- "$target")/.socks5-router.restore.XXXXXX") || { failed=1; index=$((index+1)); continue; }
            if ! { cp -p -- "$stage/backup.$index" "$temporary" && mv -f -- "$temporary" "$target"; }; then
                rm -f -- "$temporary"; failed=1
            fi
        else rm -f -- "$target" || failed=1; fi
        index=$((index+1))
    done
    (( failed == 0 ))
}

apply_commit() {
    local stage=$1
    (( APPLY_CANCELLED == 0 )) || return 1
    atomic_install "$stage/state.json" "$STATE_FILE" 600 || return 1
    atomic_install "$stage/config.json" "$CONFIG_FILE" 640 "$CONFIG_GROUP" || return 1
    atomic_install "$stage/unit" "$UNIT_FILE" 644 || return 1
    service_ctl daemon-reload || return 1
    if jq -e '.inbound_enabled' "$stage/state.json" >/dev/null; then
        service_ctl enable "$SERVICE" && reset_failed_service && \
            service_ctl restart "$SERVICE" && wait_started || return 1
    else service_ctl disable "$SERVICE" && service_ctl stop "$SERVICE" || return 1; fi
}

apply_rollback() {
    local stage=$1 was_active=$2 was_enabled=$3 failed=0
    if [[ -f $UNIT_FILE ]]; then
        service_ctl stop "$SERVICE" || { error '无法停止候选服务，已保留当前配置。'; return 1; }
        if (( was_enabled == 0 )); then service_ctl disable "$SERVICE" || failed=1; fi
    fi
    restore_files "$stage" || failed=1
    service_ctl daemon-reload || failed=1
    if [[ -f $UNIT_FILE ]]; then
        if (( was_enabled )); then service_ctl enable "$SERVICE" || failed=1;
        else service_ctl disable "$SERVICE" || failed=1; fi
    fi
    if (( failed == 0 && was_active )); then
        reset_failed_service || failed=1
        if (( failed == 0 )); then
            service_ctl restart "$SERVICE" && wait_started || failed=1
        fi
    fi
    if (( failed )); then
        service_ctl stop "$SERVICE" || :
        error '恢复旧配置也发生错误，服务保持停止，请检查文件与 systemd。'; return 1
    fi
    warn '应用失败，已恢复之前的配置和运行状态。'
}

apply_state() {
    local source=$1 force_probe=${2:-0} stage normalized old_port=0 port=0 enabled was_active=0 was_enabled=0 result=0
    normalized=$(normalize_state "$source") || return 1
    stage=$(mktemp -d "$BASE/.transaction.XXXXXX") || return 1
    CURRENT_STAGE=$stage
    printf '%s\n' "$normalized" > "$stage/state.json" || { rm -rf -- "$stage"; CURRENT_STAGE=; return 1; }
    if ! render_config "$stage/state.json" > "$stage/config.json"; then rm -rf -- "$stage"; CURRENT_STAGE=; return 1; fi
    if ! "$XRAY" run -test -config "$stage/config.json"; then rm -rf -- "$stage"; CURRENT_STAGE=; return 1; fi
    enabled=$(jq -r '.inbound_enabled' "$stage/state.json")
    if (( force_probe )) || [[ $enabled == true && $(jq -r '.mode' "$stage/state.json") != direct ]]; then
        if ! verify_upstream "$stage/state.json"; then rm -rf -- "$stage"; CURRENT_STAGE=; return 1; fi
    fi
    service_active && was_active=1
    service_ctl is-enabled --quiet "$SERVICE" && was_enabled=1
    [[ ! -f $STATE_FILE ]] || old_port=$(jq -r '.port // 0' "$STATE_FILE")
    port=$(jq -r '.port // 0' "$stage/state.json")
    if [[ $enabled == true ]] && ! (( was_active && port == old_port )); then
        if ! port_free "$port"; then rm -rf -- "$stage"; CURRENT_STAGE=; error '监听端口已占用或查询失败。'; return 1; fi
    fi
    render_unit > "$stage/unit" || { rm -rf -- "$stage"; CURRENT_STAGE=; return 1; }
    if ! snapshot_files "$stage"; then rm -rf -- "$stage"; CURRENT_STAGE=; return 1; fi
    APPLY_CANCELLED=0
    trap 'APPLY_CANCELLED=1' INT TERM
    if [[ -f $UNIT_FILE ]] && ! service_ctl stop "$SERVICE"; then
        trap 'exit 130' INT TERM
        rm -rf -- "$stage"; CURRENT_STAGE=; return 1
    fi
    if apply_commit "$stage"; then
        if [[ $enabled == true ]]; then success '配置已生效，服务已设置为开机启动。';
        else success '配置已保存；未安装入站，服务保持停止并关闭开机启动。'; fi
    else
        result=1
        APPLY_CANCELLED=0
        apply_rollback "$stage" "$was_active" "$was_enabled" || :
    fi
    trap 'exit 130' INT TERM
    rm -rf -- "$stage"; CURRENT_STAGE=
    return "$result"
}

show_state() {
    local normalized
    require_state || return 1
    normalized=$(normalize_state "$STATE_FILE") || return 1
    jq . <<< "$normalized"
}

check_state() {
    local expected actual failed=0
    require_runtime || return 1
    expected=$(render_config "$STATE_FILE" | jq -cS .) || return 1
    if actual=$(jq -cS . "$CONFIG_FILE") && [[ $expected == "$actual" ]]; then
        console_line 32 '[通过] 状态文件、入站、出站、分流和来源 IP 路由规则。'
    else error 'state.json 与 config.json 无法读取或不一致，请通过修改配置菜单修正。'; failed=1; fi
    "$XRAY" run -test -config "$CONFIG_FILE" || failed=1
    if inbound_installed; then
        if service_active; then console_line 32 '[通过] systemd 服务运行中。'
        else error '服务当前未运行。'; failed=1; fi
    else warn '未安装入站，服务保持停止。'; fi
    if [[ $(jq -r '.mode' "$STATE_FILE") != direct ]]; then
        if verify_upstream "$STATE_FILE"; then console_line 32 '[通过] 上游接受当前账号密码。'
        else failed=1; fi
    fi
    return "$failed"
}

diagnostics() {
    local failed=0
    require_state || return 1
    console_header '配置检查与上游认证'
    check_state || failed=1
    console_header '服务状态'
    if ! service_ctl status --no-pager "$SERVICE"; then inbound_installed && failed=1; fi
    console_header '最近 40 条日志'
    journalctl -u "$SERVICE" -n 40 --no-pager || failed=1
    return "$failed"
}

restart_service() {
    local expected actual
    require_inbound && require_runtime || return 1
    expected=$(render_config "$STATE_FILE" | jq -cS .) || return 1
    actual=$(jq -cS . "$CONFIG_FILE") || return 1
    [[ $expected == "$actual" ]] || { error '配置与状态不一致，请重新应用。'; return 1; }
    "$XRAY" run -test -config "$CONFIG_FILE" && reset_failed_service && \
        service_ctl restart "$SERVICE" && wait_started
}

stop_service() {
    require_state || return 1
    service_ctl stop "$SERVICE" && success '服务已停止，开机启动设置保留。'
}
