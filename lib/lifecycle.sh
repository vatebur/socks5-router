#!/usr/bin/env bash
# Initial deployment, manager upgrades and complete uninstallation.

deploy() {
    local state=$1 archive=${2:-}
    require_root || return 1
    [[ ! -f $STATE_FILE && ! -f $UNIT_FILE ]] || { error '已有服务，请通过菜单修改或先卸载。'; return 1; }
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || { error '需要使用 systemd 的 Linux 服务器。'; return 1; }
    normalize_state "$state" >/dev/null || return 1
    ensure_dependencies || { error '部署依赖检查失败，请检查上述依赖或软件源错误。'; return 1; }
    prepare_dirs || { error '创建服务账号或安装目录失败，请检查上述权限错误。'; return 1; }
    install_manager || { error '安装管理脚本及 socks5-router 命令失败。'; return 1; }
    install_core "$archive" "${OFFLINE_RELEASE:-}" || { error '安装 Xray 核心失败，请检查下载、SHA256 校验或核心版本。'; return 1; }
    if jq -e '.upstream!=null' "$state" >/dev/null; then apply_state "$state" 1;
    else apply_state "$state"; fi
}

uninstall_service() {
    local load_state uid gid directory
    UNINSTALL_COMPLETED=0
    warn '将彻底删除 SOCKS5 服务、核心、管理脚本、全部配置及专用系统账号和用户组。'
    ask '输入 DELETE 确认卸载' '' || return 1
    [[ $REPLY == DELETE ]] || { hint '已取消。'; return 0; }
    load_state=$(service_ctl show --property=LoadState --value "$SERVICE") || {
        error '无法检查 systemd 服务状态，卸载未完成。'; return 1;
    }
    if [[ -f $UNIT_FILE || ( -n $load_state && $load_state != not-found ) ]]; then
        if ! { service_ctl stop "$SERVICE" && service_ctl disable "$SERVICE"; }; then
            error '无法停止或禁用服务，卸载未完成。'; return 1
        fi
        reset_failed_service || { error '无法清理服务失败状态，卸载未完成。'; return 1; }
    fi
    if uid=$(id -u "$ACCOUNT" 2>/dev/null); then
        (( uid != 0 )) || { error '专用服务账号意外指向 root，卸载未完成。'; return 1; }
        userdel "$ACCOUNT" || { error '专用系统账号删除失败，卸载未完成。'; return 1; }
    fi
    if gid=$(getent group "$ACCOUNT"); then
        IFS=: read -r _ _ gid _ <<< "$gid"
        [[ $gid != 0 ]] || { error '专用用户组意外指向 root，卸载未完成。'; return 1; }
        groupdel "$ACCOUNT" || { error '专用用户组删除失败，卸载未完成。'; return 1; }
    fi
    for directory in "$ROOT_PREFIX/etc/systemd/system" "$ROOT_PREFIX/run/systemd/system"; do
        rm -f -- "$directory/$SERVICE" "$directory"/*.wants/"$SERVICE" \
            "$directory"/*.requires/"$SERVICE" "$directory"/*.upholds/"$SERVICE" \
            "$directory"/.socks5-router.* || return 1
        rm -rf -- "$directory/$SERVICE.d" || return 1
    done
    rm -f -- "$UNIT_FILE" "$COMMAND_FILE" "$(dirname -- "$COMMAND_FILE")"/.socks5-router.* || return 1
    rm -rf -- "$BASE" "$LIB" || return 1
    service_ctl daemon-reload || return 1
    rm -f -- "$LOCK_FILE" || return 1
    UNINSTALL_COMPLETED=1
    success '已彻底卸载：服务、程序、配置、锁文件及专用系统账号和用户组均已清理。'
}

version_newer() {
    local candidate=$1 current=$2 a b c x y z
    [[ $candidate =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ &&
       $current =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]] || return 1
    IFS=. read -r a b c <<< "$candidate"
    IFS=. read -r x y z <<< "$current"
    (( 10#$a > 10#$x || (10#$a == 10#$x && 10#$b > 10#$y) ||
        (10#$a == 10#$x && 10#$b == 10#$y && 10#$c > 10#$z) ))
}

replace_manager() {
    local candidate=$1 stage=$2 index=0 target temporary failed=0 original_resource=$RESOURCE_DIR
    local path
    local -a targets=()
    for path in "${MANAGER_FILES[@]}"; do targets+=("$LIB/$path"); done
    targets+=("$COMMAND_FILE")
    for target in "${targets[@]}"; do
        if [[ -f $target ]]; then cp -p -- "$target" "$stage/manager.$index" || return 1; fi
        index=$((index+1))
    done
    install -d -m 755 "$LIB" "$(dirname -- "$COMMAND_FILE")" || return 1
    RESOURCE_DIR=$candidate
    if ! install_manager; then failed=1; fi
    RESOURCE_DIR=$original_resource
    (( failed )) || return 0
    index=0
    for target in "${targets[@]}"; do
        if [[ -f $stage/manager.$index ]]; then
            temporary=$(mktemp "$(dirname -- "$target")/.socks5-router.upgrade-restore.XXXXXX") || return 1
            cp -p -- "$stage/manager.$index" "$temporary" && mv -f -- "$temporary" "$target" || return 1
        else rm -f -- "$target" || return 1; fi
        index=$((index+1))
    done
    error '升级安装失败，已恢复原管理脚本。'; return 1
}

upgrade_manager() {
    local stage candidate latest expected actual rc=0
    UPGRADE_COMPLETED=0
    stage=$(mktemp -d /tmp/socks5-router-upgrade.XXXXXX) || return 1
    CURRENT_STAGE=$stage
    if ! download_release "$stage"; then
        rm -rf -- "$stage"; CURRENT_STAGE=
        error '下载或校验最新发行版失败，未修改现有管理脚本。'; return 1
    fi
    candidate="$stage/socks5-router"
    latest=$(bash "$candidate/socks5.sh" --version) || { rm -rf -- "$stage"; CURRENT_STAGE=; return 1; }
    if ! version_newer "$latest" "$VERSION"; then
        if [[ $latest == "$VERSION" ]]; then
            success "已是最新版本：$VERSION"
            hint '升级仅跟随已发布的稳定版；未发布的修复不会出现在升级菜单中。'
        elif [[ $latest =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]]; then hint "当前版本 $VERSION 高于稳定发行版 $latest，无需升级。";
        else rm -rf -- "$stage"; CURRENT_STAGE=; error '发行包版本号无效。'; return 1; fi
        rm -rf -- "$stage"; CURRENT_STAGE=
        upgrade_core || return 1
        (( CORE_UPDATED == 0 )) || UPGRADE_COMPLETED=1
        return 0
    fi
    say "准备升级：$VERSION → $latest"
    if [[ -f $STATE_FILE ]]; then
        if ! bash "$candidate/socks5.sh" render --state "$STATE_FILE" --output "$stage/config.json"; then
            rm -rf -- "$stage"; CURRENT_STAGE=; error '新版本无法读取当前配置，未升级。'; return 1
        fi
        if [[ ! -x $XRAY ]] || ! "$XRAY" run -test -config "$stage/config.json"; then
            rm -rf -- "$stage"; CURRENT_STAGE=; error '新配置未通过现有 Xray 核心检查，未升级。'; return 1
        fi
        if ! expected=$(jq -cS . "$stage/config.json") || ! actual=$(jq -cS . "$CONFIG_FILE") || [[ $expected != "$actual" ]]; then
            rm -rf -- "$stage"; CURRENT_STAGE=; error '新版本与当前运行配置不兼容，未升级。'; return 1
        fi
    fi
    replace_manager "$candidate" "$stage" || rc=$?
    rm -rf -- "$stage"; CURRENT_STAGE=
    if (( rc == 0 )); then
        UPGRADE_COMPLETED=1
        success "管理脚本已升级到 $latest，当前配置保留。"
        if ! upgrade_core; then
            error '管理脚本已更新；Xray Latest 核心更新未完成，请检查上述错误并重试。'
            return 1
        fi
        hint '使用 socks5-router 呼出新版菜单（普通用户使用 sudo socks5-router）。'
    fi
    return "$rc"
}
