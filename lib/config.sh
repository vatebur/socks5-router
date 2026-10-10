#!/usr/bin/env bash
# Configuration helpers. All JSON values pass through jq, never text interpolation.

error() { printf '错误：%s\n' "$*" >&2; return 1; }
say() { printf '%s\n' "$*" >&2; }

trim() {
    local text=$1
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

parse_port() {
    local value=$1
    [[ $value =~ ^[0-9]{1,5}$ ]] || { error '端口必须为 1–65535 的整数。'; return 1; }
    value=$((10#$value))
    (( value >= 1 && value <= 65535 )) || { error '端口必须为 1–65535 的整数。'; return 1; }
    printf '%s\n' "$value"
}

normalize_ipv4() {
    local value=$1 part
    local -a octets
    [[ $value =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for part in "${octets[@]}"; do (( 10#$part <= 255 )) || return 1; done
    printf '%d.%d.%d.%d\n' "$((10#${octets[0]}))" "$((10#${octets[1]}))" \
        "$((10#${octets[2]}))" "$((10#${octets[3]}))"
}

# Result is in IP_WORDS, eight 16-bit numbers. Supports compressed and mapped IPv6.
parse_ipv6() {
    local value=${1,,} before after part count tail v4 a b c d
    local -a left=() right=()
    IP_WORDS=()
    [[ $value == *:* && $value != *%* ]] || return 1
    if [[ $value == *.* ]]; then
        tail=${value##*:}
        v4=$(normalize_ipv4 "$tail") || return 1
        IFS=. read -r a b c d <<< "$v4"
        printf -v tail '%x:%x' "$((a*256+b))" "$((c*256+d))"
        value="${value%:*}:$tail"
    fi
    [[ $value =~ ^[0-9a-f:]+$ ]] || return 1
    if [[ $value == *::* ]]; then
        before=${value%%::*}; after=${value#*::}
        [[ $after != *::* && ( -z $before || ( $before != :* && $before != *: ) ) &&
           ( -z $after || ( $after != :* && $after != *: ) ) ]] || return 1
        [[ -z $before ]] || IFS=: read -r -a left <<< "$before"
        [[ -z $after ]] || IFS=: read -r -a right <<< "$after"
        count=$((${#left[@]}+${#right[@]}))
        (( count < 8 )) || return 1
    else
        [[ $value != :* && $value != *: ]] || return 1
        IFS=: read -r -a left <<< "$value"
        (( ${#left[@]} == 8 )) || return 1
        count=8
    fi
    for part in "${left[@]}"; do
        [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
        IP_WORDS+=("$((16#$part))")
    done
    while (( ${#IP_WORDS[@]} < 8-${#right[@]} )); do IP_WORDS+=(0); done
    for part in "${right[@]}"; do
        [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
        IP_WORDS+=("$((16#$part))")
    done
}

format_ipv6() {
    local i start=-1 length=0 current=-1 size=0 prefix='' suffix='' word result=''
    for ((i=0;i<8;i++)); do
        if (( IP_WORDS[i] == 0 )); then
            (( size > 0 )) || current=$i
            size=$((size+1))
            if (( size > length )); then start=$current; length=$size; fi
        else
            size=0
        fi
    done
    if (( length < 2 )); then start=-1; fi
    for ((i=0;i<8;i++)); do
        printf -v word '%x' "${IP_WORDS[i]}"
        if (( start >= 0 )); then
            if (( i < start )); then prefix+="${prefix:+:}$word";
            elif (( i >= start+length )); then suffix+="${suffix:+:}$word"; fi
        else
            result+="${result:+:}$word"
        fi
    done
    if (( start >= 0 )); then printf '%s::%s\n' "$prefix" "$suffix";
    else printf '%s\n' "$result"; fi
}

normalize_ip() {
    local value result
    value=$(trim "$1")
    if result=$(normalize_ipv4 "$value"); then printf '%s\n' "$result"; return; fi
    parse_ipv6 "$value" || { error '请输入合法 IPv4 / IPv6 地址，不能包含作用域标识。'; return 1; }
    # Go treats IPv4-mapped listening addresses as IPv4 addresses too.
    if (( IP_WORDS[0]==0 && IP_WORDS[1]==0 && IP_WORDS[2]==0 && IP_WORDS[3]==0 &&
          IP_WORDS[4]==0 && IP_WORDS[5]==65535 )); then
        printf '%d.%d.%d.%d\n' "$((IP_WORDS[6]>>8))" "$((IP_WORDS[6]&255))" \
            "$((IP_WORDS[7]>>8))" "$((IP_WORDS[7]&255))"
    else format_ipv6; fi
}

normalize_cidr() {
    local value ip prefix bits mask number i remaining normalized
    local a b c d
    value=$(trim "$1")
    ip=${value%%/*}; prefix=
    if [[ $value == */* ]]; then
        prefix=${value#*/}
        [[ $prefix =~ ^[0-9]{1,3}$ ]] || { error 'CIDR 前缀无效。'; return 1; }
        prefix=$((10#$prefix))
    fi
    if normalized=$(normalize_ipv4 "$ip"); then
        bits=32
        [[ -n $prefix ]] || prefix=32
        (( prefix <= bits )) || { error 'IPv4 CIDR 前缀应为 0–32。'; return 1; }
        IFS=. read -r a b c d <<< "$normalized"
        number=$(( (a<<24) | (b<<16) | (c<<8) | d ))
        mask=0
        (( prefix == 0 )) || mask=$(( (0xffffffff << (32-prefix)) & 0xffffffff ))
        number=$((number & mask))
        printf -v normalized '%d.%d.%d.%d' "$((number>>24))" "$(((number>>16)&255))" \
            "$(((number>>8)&255))" "$((number&255))"
    else
        parse_ipv6 "$ip" || { error '白名单只能包含合法 IP 或 CIDR。'; return 1; }
        bits=128
        [[ -n $prefix ]] || prefix=128
        (( prefix <= bits )) || { error 'IPv6 CIDR 前缀应为 0–128。'; return 1; }
        for ((i=0;i<8;i++)); do
            remaining=$((prefix-i*16))
            if (( remaining <= 0 )); then IP_WORDS[i]=0;
            elif (( remaining < 16 )); then
                IP_WORDS[i]=$((IP_WORDS[i] & ((0xffff << (16-remaining)) & 0xffff)))
            fi
        done
        normalized=$(format_ipv6) || return 1
    fi
    if (( prefix == bits )); then printf '%s\n' "$normalized";
    else printf '%s/%s\n' "$normalized" "$prefix"; fi
}

normalize_domain() {
    local value kind=domain label name
    local -a labels
    value=$(trim "$1"); value=${value,,}
    case $value in domain:*) value=${value#domain:};; full:*) kind=full; value=${value#full:};; esac
    [[ $kind != domain || $value != '*.'* ]] || value=${value#\*.}
    value=${value%.}
    [[ ${#value} -le 253 && $value != *[!a-z0-9.-]* && $value != .* && $value != *..* &&
       $value != *[.:/] && $value != '' && ! $value =~ ^[0-9.]+$ ]] || {
        error '请输入 ASCII 域名（国际化域名请使用 Punycode），不要填写 URL、端口或 IP。'; return 1;
    }
    IFS=. read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || {
            error '域名格式无效。'; return 1;
        }
    done
    name="$kind:$value"
    printf '%s\n' "$name"
}

normalize_host() {
    local value result
    value=$(trim "$1")
    if [[ $value == \[*\] ]]; then value=${value:1:${#value}-2}; fi
    if [[ $value == *:* || $value =~ ^[0-9.]+$ ]]; then
        result=$(normalize_ip "$value") || return 1
        [[ $result != '0.0.0.0' && $result != '::' ]] || { error 'B 地址必须为可达地址，不能使用通配地址。'; return 1; }
    else
        [[ $value != *:* && $value != '*.'* ]] || return 1
        result=$(normalize_domain "$value") || return 1
        result=${result#domain:}
    fi
    printf '%s\n' "$result"
}

valid_credential() {
    printf '%s' "$1" | jq -Rse 'utf8bytelength >= 1 and utf8bytelength <= 255 and
        (explode | all(.[]; .>=32 and (. <127 or .>159)))' >/dev/null || {
        error '账号和密码必须为 1–255 个 UTF-8 字节，不能含控制字符。'; return 1;
    }
}

normalize_state() {
    local file=$1 state listen host value domains='' whitelist='' result
    state=$(jq -cse 'if length==1 then .[0] else error("JSON 必须只有一个对象") end |
      def account: type=="string" and utf8bytelength>=1 and utf8bytelength<=255 and
        (explode | all(.[]; .>=32 and (. <127 or .>159)));
      def port: type=="number" and floor==. and .>=1 and .<=65535;
      def text: type=="string" and (explode | all(.[]; .>=32 and (. <127 or .>159)));
      def strings: type=="array" and all(.[];text);
      if type=="object" and keys==(["schema","role","listen","port","username","password",
        "whitelist","mode","domains","upstream"]|sort) and
        .schema==1 and (.role=="A" or .role=="B") and (.listen|text) and
        (.port|port) and (.username|account) and (.password|account) and
        (.whitelist|strings) and (.domains|strings) and
        (.mode=="direct" or .mode=="domain" or .mode=="global") and
        (.upstream==null or (.upstream|type=="object" and keys==(["host","port","username","password"]|sort)
          and (.host|text) and (.port|port) and (.username|account) and (.password|account))) and
        (.role!="B" or (.mode=="direct" and .domains==[] and .upstream==null)) and
        (.mode=="direct" or .upstream!=null) and (.mode!="domain" or (.domains|length)>0)
      then . else error("状态配置字段、账号或分流模式无效") end' "$file") || return 1
    listen=$(normalize_ip "$(jq -r '.listen' <<< "$state")") || return 1
    while IFS= read -r value; do
        result=$(normalize_domain "$value") || return 1
        domains+="$result"$'\n'
    done < <(jq -r '.domains[]' <<< "$state")
    while IFS= read -r value; do
        result=$(normalize_cidr "$value") || return 1
        whitelist+="$result"$'\n'
    done < <(jq -r '.whitelist[]' <<< "$state")
    domains=$(printf '%s' "$domains" | jq -Rsc 'split("\n")|map(select(length>0))|unique') || return 1
    whitelist=$(printf '%s' "$whitelist" | jq -Rsc 'split("\n")|map(select(length>0))|unique') || return 1
    state=$(jq --arg listen "$listen" --argjson domains "$domains" --argjson whitelist "$whitelist" \
        '.listen=$listen|.domains=$domains|.whitelist=$whitelist' <<< "$state") || return 1
    if [[ $(jq -r '.upstream!=null' <<< "$state") == true ]]; then
        host=$(normalize_host "$(jq -r '.upstream.host' <<< "$state")") || return 1
        state=$(jq --arg host "$host" '.upstream.host=$host' <<< "$state") || return 1
    fi
    printf '%s\n' "$state"
}

render_config() {
    local normalized
    normalized=$(normalize_state "$1") || return 1
    jq --slurpfile template "$RESOURCE_DIR/templates/xray.json" \
        -f "$RESOURCE_DIR/templates/render.jq" <<< "$normalized"
}

port_free() {
    local output line
    # ss can exit 0 after a netlink permission failure; do not treat its empty
    # result as proof of a free port. Inspect its diagnostics as well.
    output=$(LC_ALL=C ss -H -ltn "sport = :$1" 2>&1) || { error '无法查询 TCP 监听端口。'; return 2; }
    while IFS= read -r line; do
        [[ -z $line || $line =~ ^[[:space:]]*LISTEN[[:space:]] ]] || {
            error '无法可靠查询 TCP 端口，请检查 ss 的运行权限。'; return 2;
        }
    done <<< "$output"
    [[ -z $output ]]
}

choose_port() {
    local candidate attempt rc
    for ((attempt=0;attempt<256;attempt++)); do
        candidate=$((16384 + ((RANDOM<<15 | RANDOM) % 44616)))
        if port_free "$candidate"; then printf '%s\n' "$candidate"; return 0;
        else rc=$?; (( rc != 2 )) || return 2; fi
    done
    error '未找到空闲 TCP 端口，请手动指定。'
}

new_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; return; fi
    local -a bytes
    read -r -a bytes <<< "$(od -An -N16 -tu1 /dev/urandom)"
    (( ${#bytes[@]} == 16 )) || return 1
    bytes[6]=$(( (bytes[6]&15)|64 )); bytes[8]=$(( (bytes[8]&63)|128 ))
    printf '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n' "${bytes[@]}"
}

# Binary auth bytes are sent through an FD; never stored in a Bash variable.
auth_packet() {
    local LC_ALL=C username=$1 password=$2 octal
    printf '\001'
    printf -v octal '\\%03o' "${#username}"; printf '%b' "$octal"; printf '%s' "$username"
    printf -v octal '\\%03o' "${#password}"; printf '%b' "$octal"; printf '%s' "$password"
}

auth_exchange() {
    local fd=$1 username=$2 password=$3 reply
    printf '\005\001\002' >&"$fd" || return 1
    reply=$(dd bs=1 count=2 status=none <&"$fd" | od -An -tx1 | tr -d ' \n') || return 1
    [[ $reply == 0502 ]] || { error 'B 未接受 SOCKS5 用户名密码认证。'; return 1; }
    auth_packet "$username" "$password" >&"$fd" || return 1
    reply=$(dd bs=1 count=2 status=none <&"$fd" | od -An -tx1 | tr -d ' \n') || return 1
    [[ $reply == 0100 ]] || { error 'B 的 SOCKS5 用户名或密码不匹配。'; return 1; }
}

probe_auth() {
    local file=$1 host port username password fd rc=0
    host=$(jq -r '.upstream.host' "$file") || return 1
    port=$(jq -r '.upstream.port' "$file") || return 1
    username=$(jq -r '.upstream.username' "$file") || return 1
    password=$(jq -r '.upstream.password' "$file") || return 1
    exec {fd}<>"/dev/tcp/$host/$port" || { error '无法连接 B。'; return 1; }
    auth_exchange "$fd" "$username" "$password" || rc=$?
    exec {fd}>&-
    return "$rc"
}

verify_upstream() {
    say '正在核对 B 的 SOCKS5 用户名密码认证……'
    timeout --kill-after=2 8 bash "$SCRIPT_PATH" _probe --state "$1" || {
        error '上游认证未通过（连接失败、账号不匹配或超时）。'; return 1;
    }
}
