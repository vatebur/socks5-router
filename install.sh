#!/usr/bin/env bash
# Download and verify the latest GitHub release, then open the interactive menu.
set -Eeuo pipefail
REPOSITORY=vatebur/socks5-router
DEPENDENCY_MANAGER=${DEPENDENCY_MANAGER:-}
DEPENDENCY_REFRESHED=${DEPENDENCY_REFRESHED:-0}

# Human-facing output only. Keep redirected logs and machine-readable stdout
# free of escape sequences, and respect terminals without colour support.
console_write() {
    local style=$1 message=$2 fd=${3:-2}
    if [[ -t $fd && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
        printf '\033[%sm%s\033[0m' "$style" "$message" >&"$fd"
    else printf '%s' "$message" >&"$fd"; fi
}

console_line() {
    console_write "$1" "$2" "${3:-2}"
    printf '\n' >&"${3:-2}"
}

console_rule() { console_line 90 '────────────────────────────────────────────'; }

console_header() {
    printf '\n' >&2
    console_line '1;36' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    console_line 1 "  $1"
    [[ -z ${2:-} ]] || console_line 90 "  $2"
    console_rule
}

console_item() {
    console_write '1;36' "  $1) "
    console_line "${3:-0}" "$2"
}

installer_error() { console_line '1;31' "安装失败：$*"; return 1; }

# Shared with socks5.sh. Like v2ray-agent's installTools, check tools before
# downloading missing packages from the distribution's repositories.
dependency_ready() {
    local tool=$1 version bundle
    if [[ $tool == ca-certificates ]]; then
        for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
            /etc/ssl/ca-bundle.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
            [[ ! -s $bundle ]] || return 0
        done
        return 1
    fi
    command -v "$tool" >/dev/null 2>&1 || return 1
    case $tool in
        jq)
            version=$(jq --version 2>/dev/null) || return 1
            [[ $version =~ ^jq-([0-9]{1,4})\.([0-9]{1,4})(\.|-|$) ]] || return 1
            (( 10#${BASH_REMATCH[1]} > 1 ||
                (10#${BASH_REMATCH[1]} == 1 && 10#${BASH_REMATCH[2]} >= 6) )) || return 1
            jq -en '("ok" | utf8bytelength) == 2' >/dev/null 2>&1;;
        unzip) unzip -v >/dev/null 2>&1;;
        ss) ss -V >/dev/null 2>&1;;
        awk) awk 'BEGIN {exit 0}' </dev/null >/dev/null 2>&1;;
        useradd|userdel|groupdel|getent) "$tool" --help >/dev/null 2>&1;;
        *) "$tool" --version >/dev/null 2>&1;;
    esac
}

dependency_manager() {
    case $DEPENDENCY_MANAGER in
        apt-get|dnf|yum) return 0;;
        '') ;;
        *) installer_error "不支持的包管理器：$DEPENDENCY_MANAGER"; return 1;;
    esac
    if command -v apt-get >/dev/null; then
        DEPENDENCY_MANAGER=apt-get
    elif command -v dnf >/dev/null; then DEPENDENCY_MANAGER=dnf
    elif command -v yum >/dev/null; then DEPENDENCY_MANAGER=yum
    else installer_error '未识别包管理器；支持 apt-get、dnf、yum，请手动安装缺少的依赖。'; return 1; fi
}

dependency_package() {
    case $1 in
        jq|curl|unzip|tar|ca-certificates) printf '%s\n' "$1";;
        ss) if [[ $DEPENDENCY_MANAGER == apt-get ]]; then printf 'iproute2\n'; else printf 'iproute\n'; fi;;
        flock) printf 'util-linux\n';;
        awk) printf 'gawk\n';;
        useradd|userdel|groupdel) if [[ $DEPENDENCY_MANAGER == apt-get ]]; then printf 'passwd\n'; else printf 'shadow-utils\n'; fi;;
        getent) if [[ $DEPENDENCY_MANAGER == apt-get ]]; then printf 'libc-bin\n'; else printf 'glibc-common\n'; fi;;
        sha256sum|timeout|od|dd|install|stat|mktemp) printf 'coreutils\n';;
        *) installer_error "未知依赖：$1"; return 1;;
    esac
}

dependency_refresh() {
    (( ! DEPENDENCY_REFRESHED )) || return 0
    console_line 36 "正在刷新 $DEPENDENCY_MANAGER 软件源……"
    case $DEPENDENCY_MANAGER in
        apt-get) apt-get update || return 1;;
        dnf) dnf makecache || return 1;;
        yum) yum makecache || return 1;;
    esac
    DEPENDENCY_REFRESHED=1
}

ensure_tools() {
    local tool package
    local -a missing=() packages=()
    for tool in "$@"; do
        dependency_ready "$tool" || missing+=("$tool")
    done
    (( ${#missing[@]} )) || return 0
    console_line 33 "需要安装或更新的依赖：${missing[*]}"
    (( EUID == 0 )) || { installer_error '自动安装依赖需要 root，请使用 sudo 或手动安装上述工具。'; return 1; }
    dependency_manager || return 1
    for tool in "${missing[@]}"; do
        package=$(dependency_package "$tool") || return 1
        [[ " ${packages[*]} " == *" $package "* ]] || packages+=("$package")
    done
    # CentOS may provide jq through EPEL, as in the reference installTools.
    if [[ $DEPENDENCY_MANAGER != apt-get && -f /etc/centos-release && " ${packages[*]} " == *' jq '* ]]; then
        if ! rpm -q epel-release >/dev/null 2>&1; then
            console_line 36 '正在安装 CentOS EPEL 软件源……'
            "$DEPENDENCY_MANAGER" install -y epel-release || { installer_error 'EPEL 软件源安装失败。'; return 1; }
            DEPENDENCY_REFRESHED=0
        fi
    fi
    dependency_refresh || { installer_error '软件源刷新失败，请检查网络及软件源配置。'; return 1; }
    console_line 36 "正在下载并安装软件包：${packages[*]}"
    if [[ $DEPENDENCY_MANAGER == apt-get ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || {
            installer_error '依赖安装失败，请检查包管理器输出。'; return 1;
        }
    else
        "$DEPENDENCY_MANAGER" install -y "${packages[@]}" || {
            installer_error '依赖安装失败，请检查包管理器输出。'; return 1;
        }
    fi
    hash -r
    for tool in "$@"; do
        if ! dependency_ready "$tool"; then
            if [[ $tool == jq ]]; then installer_error '安装后 jq 仍不可用或版本低于 1.6，请检查系统软件源。';
            else installer_error "安装后依赖仍不可用：$tool"; fi
            return 1
        fi
    done
    console_line 32 '依赖检查通过。'
}

bootstrap_tools() { ensure_tools curl jq tar sha256sum awk mktemp ca-certificates; }

release_metadata() {
    jq -er --arg repo "$REPOSITORY" '
      if .draft==false and .prerelease==false then . else error("没有稳定发行版") end |
      (.assets | map(select(.name|test("^socks5-router(-v[0-9][0-9A-Za-z.-]*)?\\.tar\\.gz$"))) |
         sort_by(if .name=="socks5-router.tar.gz" then 0 else 1 end) | .[0]) as $package |
      (.assets | map(select(.name=="SHA256SUMS")) | .[0]) as $checksum |
      if $package==null or $checksum==null then error("发行版缺少安装包或 SHA256SUMS")
      elif ($package.browser_download_url|startswith("https://github.com/"+$repo+"/releases/download/")) and
           ($checksum.browser_download_url|startswith("https://github.com/"+$repo+"/releases/download/"))
      then [$package.name,$package.browser_download_url,$checksum.browser_download_url]|@tsv
      else error("发行版下载地址无效") end' "$1"
}

verify_package() {
    local archive=$1 manifest=$2 name=$3 expected actual
    expected=$(awk -v name="$name" '$2==name || $2=="*"name {print $1}' "$manifest") || return 1
    [[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || { installer_error '校验清单中缺少唯一的安装包 SHA256。'; return 1; }
    actual=$(sha256sum -- "$archive") || return 1
    [[ ${actual%% *} == "${expected,,}" ]] || { installer_error '安装包 SHA256 不匹配。'; return 1; }
}

download_release() {
    local stage=$1
    local metadata name package_url checksum_url
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 \
        "https://api.github.com/repos/$REPOSITORY/releases/latest" -o "$stage/release.json" || return 1
    metadata=$(release_metadata "$stage/release.json") || return 1
    IFS=$'\t' read -r name package_url checksum_url <<< "$metadata"
    console_line 36 "正在下载 $name……"
    curl -fSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 \
        "$package_url" -o "$stage/package.tar.gz" || return 1
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 \
        "$checksum_url" -o "$stage/SHA256SUMS" || return 1
    verify_package "$stage/package.tar.gz" "$stage/SHA256SUMS" "$name" || return 1
    tar -tzf "$stage/package.tar.gz" > "$stage/files" || return 1
    if ! awk '/^\// || /(^|\/)\.\.(\/|$)/ || !/^socks5-router\// {bad=1} END {exit bad}' "$stage/files"; then
        installer_error '安装包目录结构无效。'; return 1
    fi
    tar --no-same-owner --no-same-permissions -xzf "$stage/package.tar.gz" -C "$stage" || return 1
    [[ -f $stage/socks5-router/socks5.sh && -f $stage/socks5-router/install.sh &&
       -f $stage/socks5-router/lib/config.sh && -f $stage/socks5-router/templates/xray.json &&
       -f $stage/socks5-router/templates/render.jq ]] || {
        installer_error '最新发行版尚未包含 Bash 版本，请先发布 v0.2.0 或更新版本。'; return 1;
    }
}

installer_main() {
    if [[ ${1:-} == --help ]]; then
        printf '%s\n' '用法：sudo bash install.sh [socks5.sh 的选项]' '下载 GitHub 最新稳定版安装包，校验 SHA256 后打开中文菜单。'
        return 0
    fi
    (( EUID == 0 )) || { installer_error '请使用 sudo bash install.sh。'; return 1; }
    bootstrap_tools || return 1
    umask 077
    INSTALL_STAGE=$(mktemp -d /tmp/socks5-router-install.XXXXXX) || return 1
    trap 'rm -rf -- "$INSTALL_STAGE"' EXIT
    download_release "$INSTALL_STAGE" || return 1
    if [[ -t 0 ]]; then bash "$INSTALL_STAGE/socks5-router/socks5.sh" "$@";
    elif [[ -r /dev/tty ]]; then bash "$INSTALL_STAGE/socks5-router/socks5.sh" "$@" </dev/tty;
    else installer_error '交互安装需要终端，请下载后通过 SSH 终端运行。'; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then installer_main "$@"; fi
