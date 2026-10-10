#!/usr/bin/env bash
# Pure Bash SOCKS5 deployment and maintenance. jq fills the JSON text templates.
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 4 )); then printf '%s\n' '需要 Bash 4 或更高版本。' >&2; exit 1; fi

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
RESOURCE_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
source "$RESOURCE_DIR/lib/config.sh"
source "$RESOURCE_DIR/install.sh"

VERSION=0.2.0
XRAY_VERSION=v26.3.27
SERVICE=socks5-router.service
ACCOUNT=socks5-router
ROOT_PREFIX=${SOCKS5_ROUTER_ROOT:-}
BASE="$ROOT_PREFIX/etc/socks5-router"
LIB="$ROOT_PREFIX/usr/local/lib/socks5-router"
STATE_FILE="$BASE/state.json"
CONFIG_FILE="$BASE/config.json"
PREVIOUS_FILE="$BASE/previous.json"
XRAY="$LIB/xray"
UNIT_FILE="$ROOT_PREFIX/etc/systemd/system/$SERVICE"
COMMAND_FILE="$ROOT_PREFIX/usr/local/bin/socks5-router"
CONFIG_GROUP=${SOCKS5_CONFIG_GROUP:-$ACCOUNT}
CURRENT_STAGE=
APPLY_CANCELLED=0
FORM_STATE=

require_root() { (( EUID == 0 )) || { error '此操作需要 root，请使用 sudo bash socks5.sh。'; return 1; }; }
service_ctl() { systemctl "$@"; }
service_active() { service_ctl is-active --quiet "$SERVICE"; }

ensure_jq() { ensure_tools jq; }

ensure_dependencies() {
    ensure_tools jq curl unzip tar ss flock timeout sha256sum od dd install stat useradd getent ca-certificates
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
    install -d -m 755 "$LIB/lib" "$LIB/templates" || return 1
    for path in socks5.sh install.sh lib/config.sh templates/xray.json templates/render.jq; do
        if [[ "$RESOURCE_DIR/$path" != "$LIB/$path" ]]; then
            install -m 644 -- "$RESOURCE_DIR/$path" "$LIB/$path" || return 1
        fi
    done
    chmod 755 "$LIB/socks5.sh" || return 1
    local wrapper
    wrapper=$(mktemp "$(dirname -- "$COMMAND_FILE")/.socks5-router.XXXXXX") || return 1
    printf '#!/usr/bin/env bash\nexec bash /usr/local/lib/socks5-router/socks5.sh "$@"\n' > "$wrapper" || { rm -f -- "$wrapper"; return 1; }
    chmod 755 "$wrapper" && mv -f -- "$wrapper" "$COMMAND_FILE"
}

install_core() {
    local archive=${1:-} name hash stage downloaded actual executable
    case $(uname -m) in
        x86_64) name=Xray-linux-64.zip; hash=23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae;;
        aarch64|arm64) name=Xray-linux-arm64-v8a.zip; hash=4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c;;
        *) error '自动安装仅支持 x86_64 / aarch64。'; return 1;;
    esac
    if [[ -x $XRAY ]]; then
        [[ $("$XRAY" version) == "Xray ${XRAY_VERSION#v} "* ]] && return 0
        error '现有核心版本与脚本不一致，请检查专用安装目录。'; return 1
    fi
    stage=$(mktemp -d "$LIB/.download.XXXXXX") || return 1
    downloaded="$stage/core.zip"; executable="$stage/xray"
    if [[ -n $archive ]]; then
        cp -- "$archive" "$downloaded" || { rm -rf -- "$stage"; return 1; }
    else
        say "正在下载 $name（$XRAY_VERSION）并校验 SHA256……"
        curl --fail --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 \
            --max-time 300 --retry 2 "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$name" \
            --output "$downloaded" || { rm -rf -- "$stage"; return 1; }
    fi
    actual=$(sha256sum -- "$downloaded") || { rm -rf -- "$stage"; return 1; }
    if [[ ${actual%% *} != "$hash" ]]; then
        rm -rf -- "$stage"; error 'Xray 安装包 SHA256 不匹配，未执行或安装。'; return 1
    fi
    if ! unzip -p "$downloaded" xray > "$executable"; then rm -rf -- "$stage"; return 1; fi
    chmod 755 "$executable" || { rm -rf -- "$stage"; return 1; }
    if ! "$executable" version; then rm -rf -- "$stage"; return 1; fi
    mv -f -- "$executable" "$XRAY" || { rm -rf -- "$stage"; return 1; }
    rm -rf -- "$stage"
}

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
    temporary=$(mktemp "$(dirname -- "$target")/.new.XXXXXX") || return 1
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
    for target in "$STATE_FILE" "$CONFIG_FILE" "$UNIT_FILE" "$PREVIOUS_FILE"; do
        if [[ -f $target ]]; then cp -p -- "$target" "$stage/backup.$index" || return 1; fi
        index=$((index+1))
    done
}

restore_files() {
    local stage=$1 index=0 target temporary failed=0
    for target in "$STATE_FILE" "$CONFIG_FILE" "$UNIT_FILE" "$PREVIOUS_FILE"; do
        if [[ -f $stage/backup.$index ]]; then
            temporary=$(mktemp "$(dirname -- "$target")/.restore.XXXXXX") || { failed=1; index=$((index+1)); continue; }
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
    service_ctl enable "$SERVICE" || return 1
    service_ctl reset-failed "$SERVICE" || return 1
    service_ctl restart "$SERVICE" || return 1
    wait_started || return 1
    if [[ -f $stage/backup.0 ]]; then atomic_install "$stage/backup.0" "$PREVIOUS_FILE" 600 || return 1; fi
}

apply_rollback() {
    local stage=$1 was_active=$2 was_enabled=$3 failed=0
    if [[ -f $UNIT_FILE ]]; then
        service_ctl stop "$SERVICE" || { error '无法停止候选服务，已保留当前配置。'; return 1; }
        if (( was_enabled == 0 )); then service_ctl disable "$SERVICE" || failed=1; fi
    fi
    restore_files "$stage" || failed=1
    service_ctl daemon-reload || failed=1
    if (( failed == 0 && was_active )); then
        service_ctl reset-failed "$SERVICE" || failed=1
        if (( failed == 0 )); then
            service_ctl restart "$SERVICE" && wait_started || failed=1
        fi
    fi
    if (( failed )); then
        service_ctl stop "$SERVICE" || :
        error '恢复旧配置也发生错误，服务保持停止，请检查文件与 systemd。'; return 1
    fi
    say '应用失败，已恢复之前的配置和运行状态。'
}

apply_state() {
    local source=$1 force_probe=${2:-0} stage normalized old_port='' port was_active=0 was_enabled=0 result=0
    normalized=$(normalize_state "$source") || return 1
    stage=$(mktemp -d "$BASE/.transaction.XXXXXX") || return 1
    CURRENT_STAGE=$stage
    printf '%s\n' "$normalized" > "$stage/state.json" || { rm -rf -- "$stage"; CURRENT_STAGE=; return 1; }
    if ! render_config "$stage/state.json" > "$stage/config.json"; then rm -rf -- "$stage"; CURRENT_STAGE=; return 1; fi
    if ! "$XRAY" run -test -config "$stage/config.json"; then rm -rf -- "$stage"; CURRENT_STAGE=; return 1; fi
    if (( force_probe )) || [[ $(jq -r '.mode' "$stage/state.json") != direct ]]; then
        if ! verify_upstream "$stage/state.json"; then rm -rf -- "$stage"; CURRENT_STAGE=; return 1; fi
    fi
    service_active && was_active=1
    service_ctl is-enabled --quiet "$SERVICE" && was_enabled=1
    [[ ! -f $STATE_FILE ]] || old_port=$(jq -r '.port' "$STATE_FILE")
    port=$(jq -r '.port' "$stage/state.json")
    if ! (( was_active && port == old_port )); then
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
    if apply_commit "$stage"; then say '配置已生效，服务已设置为开机启动。'
    else
        result=1
        APPLY_CANCELLED=0
        apply_rollback "$stage" "$was_active" "$was_enabled" || :
    fi
    trap 'exit 130' INT TERM
    rm -rf -- "$stage"; CURRENT_STAGE=
    return "$result"
}

deploy() {
    local state=$1 archive=${2:-}
    require_root || return 1
    [[ ! -f $STATE_FILE && ! -f $UNIT_FILE ]] || { error '已有服务，请通过菜单修改或先卸载。'; return 1; }
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || { error '需要使用 systemd 的 Linux 服务器。'; return 1; }
    normalize_state "$state" >/dev/null || return 1
    ensure_dependencies && prepare_dirs && install_core "$archive" && install_manager || return 1
    apply_state "$state"
}

show_state() {
    local reveal=${1:-0} normalized
    normalized=$(normalize_state "$STATE_FILE") || return 1
    if (( reveal )); then jq . <<< "$normalized";
    else jq '.password="********"|if .upstream!=null then .upstream.password="********" else . end' <<< "$normalized"; fi
}

check_state() {
    local expected actual
    expected=$(render_config "$STATE_FILE" | jq -cS .) || return 1
    actual=$(jq -cS . "$CONFIG_FILE") || return 1
    [[ $expected == "$actual" ]] || { error 'state.json 与 config.json 不一致，请重新应用配置。'; return 1; }
    "$XRAY" run -test -config "$CONFIG_FILE" || return 1
    say '[通过] 状态文件、入站、出站、分流和来源 IP 路由规则。'
    service_active || { error '配置正确，但服务当前未运行。'; return 1; }
    say '[通过] systemd 服务运行中。'
    if [[ $(jq -r '.mode' "$STATE_FILE") != direct ]]; then
        verify_upstream "$STATE_FILE" || return 1
        say '[通过] B 接受当前账号密码。'
    fi
}

restart_service() {
    local expected actual
    expected=$(render_config "$STATE_FILE" | jq -cS .) || return 1
    actual=$(jq -cS . "$CONFIG_FILE") || return 1
    [[ $expected == "$actual" ]] || { error '配置与状态不一致，请重新应用。'; return 1; }
    "$XRAY" run -test -config "$CONFIG_FILE" && service_ctl reset-failed "$SERVICE" && \
        service_ctl restart "$SERVICE" && wait_started
}

ask() {
    local prompt=$1 default=${2:-} secret=${3:-0}
    if (( secret )); then
        if [[ -t 0 ]]; then read -rs -p "$prompt：" REPLY || return 1; printf '\n' >&2;
        else read -r -p "$prompt：" REPLY || return 1; fi
    else read -r -p "$prompt${default:+ [$default]}：" REPLY || return 1; fi
    [[ -n $REPLY ]] || REPLY=$default
}

form_set() {
    FORM_STATE=$(SOCKS5_INPUT="$2" jq --arg key "$1" '.[$key]=env.SOCKS5_INPUT' <<< "$FORM_STATE")
}
form_json() { FORM_STATE=$(jq --arg key "$1" --argjson value "$2" '.[$key]=$value' <<< "$FORM_STATE"); }

ask_credentials() {
    local value old
    old=$(jq -r '.username // ""' <<< "$FORM_STATE")
    while :; do
        ask '用户名（auto 自动生成 UUID）' "${old:-auto}" || return 1
        value=$REPLY
        [[ $value != auto ]] || value=$(new_uuid) || return 1
        if valid_credential "$value"; then form_set username "$value" || return 1; break; fi
    done
    old=$(jq -r '.password // ""' <<< "$FORM_STATE")
    while :; do
        ask '密码（回车保留已有值，无已有值或输入 auto 时生成 UUID）' "$old" 1 || return 1
        value=$REPLY
        [[ -n $value && $value != auto ]] || value=$(new_uuid) || return 1
        if valid_credential "$value"; then form_set password "$value" || return 1; break; fi
    done
}

ask_listener() {
    local old value
    old=$(jq -r '.listen // "0.0.0.0"' <<< "$FORM_STATE")
    while :; do
        ask '监听 IP（0.0.0.0 / :: 为通配，系统支持时双栈）' "$old" || return 1
        if value=$(normalize_ip "$REPLY"); then form_set listen "$value" || return 1; break; fi
    done
    old=$(jq -r '.port // "auto"' <<< "$FORM_STATE")
    while :; do
        ask '监听端口（auto 自动选择空闲端口）' "$old" || return 1
        if [[ $REPLY == auto ]]; then value=$(choose_port) || return 1;
        elif ! value=$(parse_port "$REPLY"); then continue; fi
        form_json port "$value" || return 1
        break
    done
}

ask_list() {
    local key=$1 type=$2 old text value normalized list failed
    old=$(jq -r --arg key "$key" '.[$key]|join(" ")' <<< "$FORM_STATE")
    while :; do
        ask "$([[ $type == domain ]] && printf '通过 B 访问的域名' || printf '可信来源 IP / CIDR')" "$old" || return 1
        text=${REPLY//,/ }; text=${text//;/ }; text=${text//，/ }; text=${text//；/ }
        list=; failed=0
        # Whitespace splitting is intentional; pathname expansion stays disabled.
        local -a entries=()
        read -r -a entries <<< "$text"
        for value in "${entries[@]}"; do
            if [[ $type == domain ]]; then normalized=$(normalize_domain "$value") || { failed=1; break; };
            else normalized=$(normalize_cidr "$value") || { failed=1; break; }; fi
            list+="$normalized"$'\n'
        done
        (( failed == 0 )) || continue
        [[ -n $list ]] || { error '至少填写一个条目。'; continue; }
        list=$(printf '%s' "$list" | jq -Rsc 'split("\n")|map(select(length>0))|unique') || return 1
        form_json "$key" "$list" || return 1
        return 0
    done
}

ask_whitelist() {
    local default=n
    [[ $(jq -r '.whitelist|length' <<< "$FORM_STATE") == 0 ]] || default=y
    while :; do
        ask '启用可信来源 IP 白名单？y/n' "$default" || return 1
        case $REPLY in
            y|Y) say '支持 IPv4、IPv6、CIDR；使用逗号或空格分隔。'; ask_list whitelist ip; return $?;;
            n|N) form_json whitelist '[]'; return $?;;
            *) error '请选择 y 或 n。';;
        esac
    done
}

ask_upstream() {
    local upstream old key value
    upstream=$(jq '.upstream // {}' <<< "$FORM_STATE") || return 1
    say '请填写 B 的实际连接信息；上游账号不会自动生成。'
    for key in host port username password; do
        old=$(jq -r --arg key "$key" '.[$key] // ""' <<< "$upstream") || return 1
        while :; do
            case $key in
                host) ask 'B 地址（可达 IP 或域名）' "$old" || return 1
                      value=$(normalize_host "$REPLY") || continue;;
                port) ask 'B 端口' "$old" || return 1; value=$(parse_port "$REPLY") || continue;;
                username) ask 'B 的实际用户名' "$old" || return 1; value=$REPLY; valid_credential "$value" || continue;;
                password) ask 'B 的实际密码（已有值时回车保留）' "$old" 1 || return 1
                          value=$REPLY; valid_credential "$value" || continue;;
            esac
            if [[ $key == port ]]; then upstream=$(jq --argjson value "$value" '.port=$value' <<< "$upstream") || return 1;
            else upstream=$(SOCKS5_INPUT="$value" jq --arg key "$key" '.[$key]=env.SOCKS5_INPUT' <<< "$upstream") || return 1; fi
            break
        done
    done
    FORM_STATE=$(SOCKS5_UPSTREAM="$upstream" jq '.upstream=(env.SOCKS5_UPSTREAM|fromjson)' <<< "$FORM_STATE")
}

ask_domains() {
    say '例如 example.com full:api.example.net；普通域名含子域，full: 精确匹配。'
    ask_list domains domain
}

ask_mode() {
    local default=1 mode
    case $(jq -r '.mode' <<< "$FORM_STATE") in direct) default=2;; global) default=3;; esac
    say '1. 按域名分流   2. 跳过分流（全部直连）   3. 全局代理（全部通过 B）'
    while :; do
        ask '分流模式' "$default" || return 1
        case $REPLY in 1) mode=domain;; 2) mode=direct;; 3) mode=global;; *) error '请选择 1/2/3。'; continue;; esac
        form_set mode "$mode" || return 1
        break
    done
    if [[ $mode != direct && $(jq -r '.upstream==null' <<< "$FORM_STATE") == true ]]; then ask_upstream || return 1; fi
    [[ $mode != domain ]] || ask_domains
}

form_new() {
    FORM_STATE=$(jq -n --arg role "$1" '{schema:1,role:$role,listen:"0.0.0.0",port:null,
        username:"",password:"",whitelist:[],mode:"direct",domains:[],upstream:null}') || return 1
    ask_credentials && ask_listener && ask_whitelist || return 1
    if [[ $1 == A ]]; then form_set mode domain && ask_mode || return 1; fi
}

submit_form() {
    local temporary rc=0
    temporary=$(mktemp) || return 1
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    printf '%s\n' "$FORM_STATE" > "$temporary" || { rm -f -- "$temporary"; return 1; }
    "$@" "$temporary" || rc=$?
    rm -f -- "$temporary"
    return "$rc"
}

connection_info() {
    jq -r '"角色：\(.role)；监听：\(.listen):\(.port)；用户名：\(.username)"' "$STATE_FILE"
    say '密码可通过菜单 4 显示。B 的地址、端口和实际账号需同步填入 A。'
    say '请放行云安全组及现有主机防火墙的 TCP 端口；域名分流使用 socks5h / 远程 DNS。'
}

edit_form() {
    local selected role force_probe=0 temporary rc=0
    FORM_STATE=$(normalize_state "$STATE_FILE") || return 1
    role=$(jq -r '.role' <<< "$FORM_STATE")
    say $'1. 入站账号密码\n2. 监听地址/端口\n3. 来源 IP 白名单'
    [[ $role != A ]] || say $'4. B 的连接信息\n5. 域名列表\n6. 分流模式'
    ask '选择修改项（0 返回）' 0 || return 1
    selected=$REPLY
    case $selected in
        0) return 0;; 1) ask_credentials || return 1;; 2) ask_listener || return 1;; 3) ask_whitelist || return 1;;
        4) [[ $role == A ]] || return 1; ask_upstream || return 1; force_probe=1;;
        5) [[ $role == A ]] || return 1; ask_domains || return 1;;
        6) [[ $role == A ]] || return 1; ask_mode || return 1;; *) error '无效选项。'; return 1;;
    esac
    temporary=$(mktemp) || return 1
    printf '%s\n' "$FORM_STATE" > "$temporary" || { rm -f -- "$temporary"; return 1; }
    apply_state "$temporary" "$force_probe" || rc=$?
    rm -f -- "$temporary"
    (( rc == 0 )) && connection_info
    return "$rc"
}

uninstall_service() {
    [[ -f $STATE_FILE ]] || { error '尚未安装。'; return 1; }
    say '将删除本工具的服务、配置、凭据备份和安装目录。'
    ask '输入 DELETE 确认卸载' '' || return 1
    [[ $REPLY == DELETE ]] || { say '已取消。'; return 0; }
    service_ctl stop "$SERVICE" && service_ctl disable "$SERVICE" || return 1
    rm -f -- "$UNIT_FILE" "$COMMAND_FILE" || return 1
    rm -rf -- "$BASE" "$LIB" || return 1
    service_ctl daemon-reload || return 1
    say '已卸载；专用无登录系统账号保留，可按需手动删除。'
}

deploy_form() {
    local file=$1
    deploy "$file" "${OFFLINE_ARCHIVE:-}" || return 1
    connection_info
    jq -r '"本次入站密码："+.password' "$STATE_FILE"
}

menu() {
    while :; do
        say $'\n轻量 SOCKS5 管理（Bash / TCP CONNECT）'
        say $'1. 部署服务器 A\n2. 部署服务器 B\n3. 查看配置（隐藏密码）\n4. 显示账号密码'
        say $'5. 检查配置及上游认证\n6. 修改配置\n7. 启动/重启\n8. 停止服务'
        say $'9. 状态和日志\n10. 恢复上一次配置\n11. 重新应用配置\n12. 卸载\n0. 退出'
        ask '请选择' '' || return 0
        case $REPLY in
            0) return 0;;
            1|2)
                if [[ -f $STATE_FILE || -f $UNIT_FILE ]]; then error '已有服务，请使用修改菜单。'; continue; fi
                local role=A; [[ $REPLY != 2 ]] || role=B
                if ! form_new "$role" || ! submit_form deploy_form; then say '部署未完成。'; fi;;
            3) show_state || :;; 4) show_state 1 || :;; 5) check_state || :;;
            6) edit_form || say '修改未完成。';; 7) restart_service || :;;
            8) service_ctl stop "$SERVICE" && say '服务已停止，开机启动设置保留。';;
            9) service_ctl status --no-pager "$SERVICE" || :; journalctl -u "$SERVICE" -n 40 --no-pager || :;;
            10) apply_state "$PREVIOUS_FILE" || :;; 11) apply_state "$STATE_FILE" || :;;
            12) uninstall_service || :;; *) error '无效选项。';;
        esac
    done
}

usage() {
    cat <<'HELP'
用法：bash socks5.sh [menu|validate|render|check|show] [选项]
  --state FILE         validate/render 所用状态 JSON
  --output FILE        render 输出文件，包含凭据，权限 600
  --xray-archive FILE  部署时使用离线官方 Xray ZIP（仍校验 SHA256）
  --version            显示脚本版本
  --help               显示帮助
默认打开中文交互菜单；validate/render 不安装服务或连接 B。
HELP
}

main() {
    local action=menu state='' output='' temporary
    OFFLINE_ARCHIVE=
    while (( $# )); do
        case $1 in
            menu|validate|render|check|show|_probe) action=$1; shift;;
            --state|--output|--xray-archive)
                (( $# >= 2 )) || { error '选项缺少参数。'; return 1; }
                case $1 in --state) state=$2;; --output) output=$2;; --xray-archive) OFFLINE_ARCHIVE=$2;; esac
                shift 2;;
            --version) printf '%s\n' "$VERSION"; return 0;; --help|-h) usage; return 0;;
            *) error "未知参数：$1"; return 1;;
        esac
    done
    if [[ $action == _probe ]]; then [[ -n $state ]] || return 1; probe_auth "$state"; return $?; fi
    if [[ $action == validate || $action == render ]]; then
        ensure_jq || return 1
        [[ -n $state ]] || { error '必须指定 --state FILE。'; return 1; }
        if [[ $action == validate ]]; then normalize_state "$state" >/dev/null && say '状态配置校验通过。';
        elif [[ -z $output ]]; then render_config "$state";
        else
            temporary=$(mktemp "$(dirname -- "$output")/.render.XXXXXX") || return 1
            if render_config "$state" > "$temporary" && chmod 600 "$temporary" && mv -f -- "$temporary" "$output"; then say "已生成 $output";
            else rm -f -- "$temporary"; return 1; fi
        fi
        return $?
    fi
    require_root || return 1
    ensure_dependencies || return 1
    command -v flock >/dev/null || { error '请先安装 util-linux（flock）。'; return 1; }
    exec 200>"$ROOT_PREFIX/run/socks5-router.lock" || return 1
    flock -n 200 || { error '已有另一管理进程运行。'; return 1; }
    umask 077
    trap '[[ -z $CURRENT_STAGE ]] || rm -rf -- "$CURRENT_STAGE"' EXIT
    trap 'exit 130' INT TERM
    case $action in check) check_state;; show) show_state;; *) menu;; esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
