#!/usr/bin/env bash
# Pure Bash SOCKS5 deployment and maintenance. jq fills the JSON text templates.
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 4 )); then printf '%s\n' '需要 Bash 4 或更高版本。' >&2; exit 1; fi

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
RESOURCE_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)

VERSION=0.4.1
SERVICE=socks5-router.service
ACCOUNT=socks5-router
ROOT_PREFIX=${SOCKS5_ROUTER_ROOT:-}
BASE="$ROOT_PREFIX/etc/socks5-router"
LIB="$ROOT_PREFIX/usr/local/lib/socks5-router"
STATE_FILE="$BASE/state.json"
CONFIG_FILE="$BASE/config.json"
XRAY="$LIB/xray"
UNIT_FILE="$ROOT_PREFIX/etc/systemd/system/$SERVICE"
COMMAND_FILE="$ROOT_PREFIX/usr/local/bin/socks5-router"
LOCK_FILE="$ROOT_PREFIX/run/socks5-router.lock"
CONFIG_GROUP=${SOCKS5_CONFIG_GROUP:-$ACCOUNT}
CURRENT_STAGE=
APPLY_CANCELLED=0
FORM_STATE=
UPGRADE_COMPLETED=0
CORE_UPDATED=0
UNINSTALL_COMPLETED=0

# Keep the installed file list shared by installation and upgrade rollback.
MANAGER_MODULES=(lib/config.sh lib/runtime.sh lib/core.sh lib/service.sh lib/lifecycle.sh lib/menu.sh)
MANAGER_FILES=(socks5.sh install.sh "${MANAGER_MODULES[@]}" templates/xray.json templates/render.jq)
source "$RESOURCE_DIR/install.sh"
for manager_module in "${MANAGER_MODULES[@]}"; do
    source "$RESOURCE_DIR/$manager_module"
done
unset manager_module

usage() {
    cat <<'HELP'
用法：bash socks5.sh [menu|validate|render|check|show|upgrade] [选项]
  --state FILE         validate/render 所用状态 JSON
  --output FILE        render 输出文件，包含凭据，权限 600
  --xray-archive FILE  使用本地官方 Xray ZIP（仍校验 SHA256）
  --xray-release FILE  离线使用已保存的官方 Latest 元数据 JSON
  --version            显示脚本版本
  --help               显示帮助
默认打开中文交互菜单；validate/render 不安装服务或连接 B。
安装后使用 socks5-router 呼出菜单（普通用户使用 sudo socks5-router）。
HELP
}

main() {
    local action=menu state='' output='' temporary
    OFFLINE_ARCHIVE=
    OFFLINE_RELEASE=
    while (( $# )); do
        case $1 in
            menu|validate|render|check|show|upgrade|_probe) action=$1; shift;;
            --state|--output|--xray-archive|--xray-release)
                (( $# >= 2 )) || { error '选项缺少参数。'; return 1; }
                case $1 in --state) state=$2;; --output) output=$2;; --xray-archive) OFFLINE_ARCHIVE=$2;; --xray-release) OFFLINE_RELEASE=$2;; esac
                shift 2;;
            --version) printf '%s\n' "$VERSION"; return 0;; --help|-h) usage; return 0;;
            *) error "未知参数：$1"; return 1;;
        esac
    done
    if [[ $action == _probe ]]; then [[ -n $state ]] || return 1; probe_auth "$state"; return $?; fi
    if [[ $action == validate || $action == render ]]; then
        ensure_jq || return 1
        [[ -n $state ]] || { error '必须指定 --state FILE。'; return 1; }
        if [[ $action == validate ]]; then normalize_state "$state" >/dev/null && success '状态配置校验通过。';
        elif [[ -z $output ]]; then render_config "$state";
        else
            temporary=$(mktemp "$(dirname -- "$output")/.render.XXXXXX") || return 1
            if render_config "$state" > "$temporary" && chmod 600 "$temporary" && mv -f -- "$temporary" "$output"; then success "已生成 $output";
            else rm -f -- "$temporary"; return 1; fi
        fi
        return $?
    fi
    require_root || return 1
    if [[ $action == check || $action == show ]]; then require_state || return 1; fi
    ensure_dependencies || return 1
    command -v flock >/dev/null || { error '请先安装 util-linux（flock）。'; return 1; }
    exec 200>"$LOCK_FILE" || return 1
    flock -n 200 || { error '已有另一管理进程运行。'; return 1; }
    umask 077
    trap '[[ -z $CURRENT_STAGE ]] || rm -rf -- "$CURRENT_STAGE"' EXIT
    trap 'exit 130' INT TERM
    # Keep the menu available even before a first deployment succeeds, including
    # when this script was launched from the installer's temporary directory.
    if [[ $action == menu ]]; then install_manager || return 1; fi
    case $action in check) diagnostics;; show) show_state;; upgrade) upgrade_manager;; *) menu;; esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
