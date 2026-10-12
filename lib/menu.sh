#!/usr/bin/env bash
# Interactive forms, component configuration and menus.

ask() {
    local prompt=$1 default=${2:-} secret=${3:-0}
    if [[ -t 0 ]]; then
        if (( secret )); then console_write '1;36' "  › $prompt：";
        else console_write '1;36' "  › $prompt${default:+ [$default]}："; fi
    fi
    if (( secret )) && [[ -t 0 ]]; then
        read -rs REPLY || return 1
        printf '\n' >&2
    else read -r REPLY || return 1; fi
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
        if [[ $value == auto ]]; then
            value=$(new_uuid) || return 1
            say "自动生成的用户名：$value"
        fi
        if valid_credential "$value"; then form_set username "$value" || return 1; break; fi
    done
    old=$(jq -r '.password // ""' <<< "$FORM_STATE")
    while :; do
        ask '密码（回车保留已有值，无已有值或输入 auto 时生成 UUID）' "$old" 1 || return 1
        value=$REPLY
        if [[ -z $value || $value == auto ]]; then
            value=$(new_uuid) || return 1
            say "自动生成的密码：$value"
        fi
        if valid_credential "$value"; then form_set password "$value" || return 1; break; fi
    done
}

wildcard_listener() {
    local disabled=1
    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        read -r disabled < /proc/sys/net/ipv6/conf/all/disable_ipv6 || disabled=1
    fi
    if [[ $disabled == 0 ]]; then printf '::\n'; else printf '0.0.0.0\n'; fi
}

ask_listener() {
    local old value
    value=$(wildcard_listener) || return 1
    form_set listen "$value" || return 1
    say "监听地址：$value（通配地址）"
    old=$(jq -r '.port // "auto"' <<< "$FORM_STATE")
    while :; do
        ask '监听端口（auto 自动选择空闲端口）' "$old" || return 1
        if [[ $REPLY == auto ]]; then
            value=$(choose_port) || return 1
            say "自动选择的监听端口：$value"
        elif ! value=$(parse_port "$REPLY"); then continue; fi
        form_json port "$value" || return 1
        break
    done
}

ask_list() {
    local key=$1 type=$2 old text value normalized list failed
    old=$(jq -r --arg key "$key" '.[$key]|join(" ")' <<< "$FORM_STATE")
    while :; do
        ask "$([[ $type == domain ]] && printf '通过上游访问的域名' || printf '可信来源 IP / CIDR')" "$old" || return 1
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
    say '请填写上游 SOCKS5 的实际连接信息；上游账号不会自动生成。'
    for key in host port username password; do
        old=$(jq -r --arg key "$key" '.[$key] // ""' <<< "$upstream") || return 1
        while :; do
            case $key in
                host) ask '上游地址（可达 IP 或域名）' "$old" || return 1
                      value=$(normalize_host "$REPLY") || continue;;
                port) ask '上游端口' "$old" || return 1; value=$(parse_port "$REPLY") || continue;;
                username) ask '上游的实际用户名' "$old" || return 1; value=$REPLY; valid_credential "$value" || continue;;
                password) ask '上游的实际密码（已有值时回车保留）' "$old" 1 || return 1
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
    local configure_upstream=${1:-0} default=1 mode
    case $(jq -r '.mode' <<< "$FORM_STATE") in direct) default=2;; global) default=3;; esac
    console_header '选择分流模式'
    console_item 1 '按域名分流'
    console_item 2 '跳过分流（全部直连）'
    console_item 3 '全局代理（全部通过上游）'
    while :; do
        ask '分流模式' "$default" || return 1
        case $REPLY in 1) mode=domain;; 2) mode=direct;; 3) mode=global;; *) error '请选择 1/2/3。'; continue;; esac
        form_set mode "$mode" || return 1
        break
    done
    if [[ $mode == direct ]]; then
        form_json upstream null && form_json domains '[]' && form_set role B || return 1
    else
        form_set role A || return 1
        if (( configure_upstream )) || [[ $(jq -r '.upstream==null' <<< "$FORM_STATE") == true ]]; then
            ask_upstream || return 1
        fi
        if [[ $mode == domain ]]; then ask_domains || return 1;
        else form_json domains '[]' || return 1; fi
    fi
    return 0
}

form_new() {
    FORM_STATE=$(jq -n '{schema:2,role:"B",inbound_enabled:false,listen:"0.0.0.0",port:null,
        username:"",password:"",whitelist:[],mode:"direct",domains:[],upstream:null}') || return 1
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
    local details line
    details=$(normalize_state "$STATE_FILE" | jq -r '
        if .inbound_enabled then
          "SOCKS5 入站：" + (if .listen|contains(":") then "["+.listen+"]" else .listen end) + ":" + (.port|tostring),
          "入站用户名："+.username, "入站密码："+.password
        else "SOCKS5 入站：未安装" end,
        (if .upstream==null then "SOCKS5 出站：未安装" else "SOCKS5 出站："+.upstream.host+":"+(.upstream.port|tostring) end),
        "分流模式："+(if .mode=="direct" then "全部直连（direct）"
          elif .mode=="domain" then "按域名分流（domain）" else "全局代理（global）" end)') || return 1
    console_header '连接信息' 'SOCKS5 入站 / 出站 / 分流配置'
    while IFS= read -r line; do
        case $line in
            *未安装) console_line 33 "  $line" 1;;
            入站用户名：*|入站密码：*) console_line '1;32' "  $line" 1;;
            *) console_line 36 "  $line" 1;;
        esac
    done <<< "$details"
    console_rule
    if inbound_installed; then
        say '将本机的可达地址、入站端口和账号填入其他机器的 SOCKS5 出站，即可作为其上游。'
        warn '请放行云安全组及现有主机防火墙的 TCP 端口；域名分流使用 socks5h / 远程 DNS。'
    fi
    hint '使用 socks5-router 呼出菜单（普通用户使用 sudo socks5-router）。'
}

edit_inbound() {
    local selected
    require_inbound && require_runtime || return 1
    FORM_STATE=$(normalize_state "$STATE_FILE") || return 1
    console_header '修改 SOCKS5 入站配置'
    console_item 1 '入站账号密码'
    console_item 2 '监听端口'
    console_item 3 '来源 IP 白名单'
    console_item 0 '返回' 90
    ask '选择入站修改项' 0 || return 1
    selected=$REPLY
    case $selected in
        0) return 0;; 1) ask_credentials || return 1;; 2) ask_listener || return 1;; 3) ask_whitelist || return 1;;
        *) error '无效选项。'; return 1;;
    esac
    submit_form apply_form 0
}

edit_outbound() {
    local selected force_probe=0
    require_outbound && require_runtime || return 1
    FORM_STATE=$(normalize_state "$STATE_FILE") || return 1
    console_header '修改 SOCKS5 出站配置'
    console_item 1 '上游连接信息'
    console_item 2 '域名列表'
    console_item 3 '分流模式'
    console_item 0 '返回' 90
    ask '选择出站修改项' 0 || return 1
    selected=$REPLY
    case $selected in
        0) return 0;; 1) ask_upstream || return 1; force_probe=1;;
        2)
            [[ $(jq -r '.mode' <<< "$FORM_STATE") == domain ]] || {
                warn '域名列表仅用于按域名分流，请先配置出站并选择按域名分流模式。'; return 1;
            }
            ask_domains || return 1;;
        3) ask_mode || return 1;; *) error '无效选项。'; return 1;;
    esac
    submit_form apply_form "$force_probe"
}

edit_menu() {
    while :; do
        console_header '修改配置'
        console_item 1 '修改 SOCKS5 入站配置'
        console_item 2 '修改 SOCKS5 出站配置'
        console_item 0 '返回' 90
        ask '请选择' '' || return 0
        case $REPLY in
            0) return 0;; 1) edit_inbound || failure '入站修改未完成。';;
            2) edit_outbound || failure '出站修改未完成。';; *) failure '无效选项。';;
        esac
    done
}

deploy_form() {
    local file=$1
    deploy "$file" "${OFFLINE_ARCHIVE:-}" || return 1
    connection_info
}

apply_form() {
    local force_probe=${1:-0} file=$2
    apply_state "$file" "$force_probe" || return 1
    connection_info
}

configure_inbound() {
    if inbound_installed; then warn '入站已安装，请通过「修改配置」→「修改 SOCKS5 入站配置」进行修改。'; return 0; fi
    if [[ -f $STATE_FILE ]]; then
        require_runtime || return 1
        FORM_STATE=$(normalize_state "$STATE_FILE") || return 1
    else
        [[ ! -f $UNIT_FILE ]] || { error '存在服务文件但缺少状态配置，请检查安装目录。'; return 1; }
        form_new || return 1
    fi
    form_json inbound_enabled true || return 1
    ask_credentials && ask_listener && ask_whitelist || return 1
    if [[ -f $STATE_FILE ]]; then submit_form apply_form 0; else submit_form deploy_form; fi
}

configure_outbound() {
    if outbound_installed; then warn '出站已安装，请通过「修改配置」→「修改 SOCKS5 出站配置」进行修改。'; return 0; fi
    if [[ -f $STATE_FILE ]]; then
        require_runtime || return 1
        FORM_STATE=$(normalize_state "$STATE_FILE") || return 1
    else form_new || return 1; fi
    ask_mode 1 || return 1
    [[ $(jq -r '.upstream!=null' <<< "$FORM_STATE") == true ]] || { warn '选择了全部直连，未安装 SOCKS5 出站。'; return 0; }
    if [[ -f $STATE_FILE ]]; then submit_form apply_form 1; else submit_form deploy_form; fi
}

remove_inbound() {
    require_inbound && require_runtime || return 1
    ask '卸载 SOCKS5 入站并清除监听账号？y/n' n || return 1
    [[ $REPLY == y || $REPLY == Y ]] || { hint '已取消。'; return 0; }
    FORM_STATE=$(normalize_state "$STATE_FILE") || return 1
    FORM_STATE=$(jq '.inbound_enabled=false|.port=null|.username=""|.password=""|.whitelist=[]' <<< "$FORM_STATE") || return 1
    submit_form apply_form 0
}

remove_outbound() {
    require_outbound && require_runtime || return 1
    ask '卸载 SOCKS5 出站及分流？y/n' n || return 1
    [[ $REPLY == y || $REPLY == Y ]] || { hint '已取消。'; return 0; }
    FORM_STATE=$(normalize_state "$STATE_FILE") || return 1
    FORM_STATE=$(jq '.upstream=null|.domains=[]|.mode="direct"|.role="B"' <<< "$FORM_STATE") || return 1
    submit_form apply_form 0
}

deployment_menu() {
    while :; do
        console_header 'SOCKS5 部署'
        console_item 1 '安装 SOCKS5 入站'
        console_item 2 '安装 SOCKS5 出站及分流'
        console_rule
        console_item 3 '卸载 SOCKS5 入站' 33
        console_item 4 '卸载 SOCKS5 出站及分流' 33
        console_item 0 '返回' 90
        ask '请选择' '' || return 0
        case $REPLY in
            0) return 0;;
            1) configure_inbound || failure '入站配置未完成。';;
            2) configure_outbound || failure '出站配置未完成。';;
            3) remove_inbound || failure '入站卸载未完成。';;
            4) remove_outbound || failure '出站卸载未完成。';;
            *) failure '无效选项。';;
        esac
    done
}

service_menu() {
    while :; do
        console_header '服务管理'
        console_item 1 '启动/重启服务'
        console_item 2 '停止服务' 33
        console_item 0 '返回' 90
        ask '请选择' '' || return 0
        case $REPLY in
            0) return 0;;
            1)
                if restart_service; then success '服务已启动。';
                else failure '服务启动未完成，请检查上述错误。'; fi;;
            2) stop_service || failure '服务停止未完成，请检查上述错误。';;
            *) failure '无效选项。';;
        esac
    done
}

menu() {
    while :; do
        console_header '轻量 SOCKS5 管理' "v$VERSION · Xray $(installed_core_version) · TCP CONNECT"
        console_item 1 'SOCKS5 部署（入站 / 出站）'
        console_item 2 '查看配置及账号密码'
        console_item 3 '检查配置、上游认证、状态和日志'
        console_item 4 '修改配置'
        console_item 5 '服务管理'
        console_item 6 '升级'
        console_rule
        console_item 7 '卸载全部' '1;31'
        console_item 0 '退出' 90
        console_rule
        hint '使用 socks5-router 呼出菜单（普通用户使用 sudo socks5-router）。'
        ask '请选择' '' || return 0
        case $REPLY in 2|3|4|5) require_state || continue;; esac
        case $REPLY in
            0) return 0;;
            1) deployment_menu;;
            2) show_state || :;; 3) diagnostics || :;;
            4) edit_menu;; 5) service_menu;;
            6) upgrade_manager || failure '升级未完成。'; (( UPGRADE_COMPLETED == 0 )) || return 0;;
            7) uninstall_service || failure '卸载未完成，请检查上述错误后重试。'; (( UNINSTALL_COMPLETED == 0 )) || return 0;;
            *) failure '无效选项。';;
        esac
    done
}
