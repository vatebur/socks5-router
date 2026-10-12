#!/usr/bin/env bash
# Xray release downloads, checksum verification and core upgrades.

installed_core_version() {
    local output
    if [[ -x $XRAY ]] && output=$("$XRAY" version 2>/dev/null) &&
       [[ $output =~ ^Xray[[:space:]]+([0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4})[[:space:]] ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else printf '未安装\n'; fi
}

core_fetch_release() {
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$1"
}

core_fetch_asset() {
    curl -fSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 "$1" -o "$2"
}

core_release_metadata() {
    jq -er --arg name "$2" '
      if .draft==false and .prerelease==false and (.tag_name|test("^v[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$"))
      then . else error("Xray Latest 不是有效稳定版") end |
      . as $release |
      ("https://github.com/XTLS/Xray-core/releases/download/"+.tag_name+"/") as $prefix |
      (.assets|map(select(.name==$name))) as $packages |
      if ($packages|length)!=1 then error("Latest 缺少唯一的当前架构安装包") else $packages[0] end |
      . as $package |
      ($release.assets|map(select(.name==($name+".dgst") and .browser_download_url==($prefix+$name+".dgst")))|.[0]) as $checksum |
      if .browser_download_url!=($prefix+$name) then error("Xray 下载地址无效") else . end |
      (if (.digest // ""|test("^sha256:[a-fA-F0-9]{64}$")) then (.digest|ltrimstr("sha256:")|ascii_downcase) else "-" end) as $hash |
      if $hash=="-" and $checksum==null then error("Latest 缺少 SHA256 校验信息") else
        [$release.tag_name,$package.browser_download_url,$hash,($checksum.browser_download_url // "-")]|@tsv end' "$1"
}

prepare_core() {
    local stage=$1 archive=${2:-} release=${3:-} name metadata version url hash checksum actual output
    case $(uname -m) in
        x86_64) name=Xray-linux-64.zip;;
        aarch64|arm64) name=Xray-linux-arm64-v8a.zip;;
        *) error '自动安装仅支持 x86_64 / aarch64。'; return 1;;
    esac
    if [[ -n $release ]]; then cp -- "$release" "$stage/release.json" || return 1;
    elif ! core_fetch_release "$stage/release.json"; then error '无法查询 Xray 官方 Latest，现有核心保留。'; return 1; fi
    metadata=$(core_release_metadata "$stage/release.json" "$name") || { error 'Xray Latest 元数据无效，未安装核心。'; return 1; }
    IFS=$'\t' read -r version url hash checksum <<< "$metadata"
    printf '%s\n' "${version#v}" > "$stage/version" || return 1
    if [[ -z $archive && $(installed_core_version) == "${version#v}" ]]; then
        success "Xray 已是官方 Latest：${version#v}"
        return 0
    fi
    if [[ $hash == - ]]; then
        core_fetch_asset "$checksum" "$stage/core.dgst" || return 1
        hash=$(awk -F '= ' '/^(SHA256|SHA2-256)=/ {print $2}' "$stage/core.dgst") || return 1
        hash=${hash,,}
        [[ $hash =~ ^[a-f0-9]{64}$ ]] || { error 'Xray 官方 SHA256 校验文件无效。'; return 1; }
    fi
    say "正在获取 Xray 官方 Latest：$version（$name），并校验 SHA256……"
    if [[ -n $archive ]]; then cp -- "$archive" "$stage/core.zip" || return 1;
    else core_fetch_asset "$url" "$stage/core.zip" || return 1; fi
    actual=$(sha256sum -- "$stage/core.zip") || return 1
    [[ ${actual%% *} == "$hash" ]] || { error 'Xray 安装包 SHA256 不匹配，未执行或安装。'; return 1; }
    unzip -p "$stage/core.zip" xray > "$stage/xray" && chmod 755 "$stage/xray" || return 1
    output=$("$stage/xray" version) || return 1
    [[ $output == "Xray ${version#v} "* ]] || { error 'Xray 核心版本与官方元数据不一致。'; return 1; }
    success "Xray ${version#v} 下载和 SHA256 校验通过。"
}

install_core() {
    local stage rc=0
    stage=$(mktemp -d "$LIB/.download.XXXXXX") || return 1
    if prepare_core "$stage" "${1:-}" "${2:-}"; then
        if [[ -f $stage/xray ]]; then atomic_install "$stage/xray" "$XRAY" 755 || rc=$?; fi
    else rc=$?; fi
    rm -rf -- "$stage"
    return "$rc"
}

upgrade_core() {
    local stage was_active=0 restored=0 rc=0 version
    CORE_UPDATED=0
    [[ -x $XRAY ]] || return 0
    stage=$(mktemp -d "$LIB/.core-upgrade.XXXXXX") || return 1
    if ! prepare_core "$stage" "${OFFLINE_ARCHIVE:-}" "${OFFLINE_RELEASE:-}"; then
        rm -rf -- "$stage"; return 1
    fi
    [[ -f $stage/xray ]] || { rm -rf -- "$stage"; return 0; }
    version=$(cat "$stage/version") || { rm -rf -- "$stage"; return 1; }
    if [[ -f $STATE_FILE ]]; then
        if ! { require_runtime && "$stage/xray" run -test -config "$CONFIG_FILE"; }; then
            rm -rf -- "$stage"; error 'Latest 核心未通过现有配置检查，旧核心保留。'; return 1;
        fi
        service_active && was_active=1
    fi
    cp -p -- "$XRAY" "$stage/previous-xray" || { rm -rf -- "$stage"; return 1; }
    atomic_install "$stage/xray" "$XRAY" 755 || rc=$?
    if (( rc == 0 && was_active )); then
        reset_failed_service && service_ctl restart "$SERVICE" && wait_started || rc=1
    fi
    if (( rc )); then
        if atomic_install "$stage/previous-xray" "$XRAY" 755; then
            restored=1
            if (( was_active )); then
                reset_failed_service && service_ctl restart "$SERVICE" && wait_started || restored=0
            fi
        fi
        if (( restored )); then
            rm -rf -- "$stage"
            error 'Latest 核心更新失败，已恢复旧核心和之前的运行状态。'
        else error "核心恢复未完成，旧核心备份保留在 $stage/previous-xray。"; fi
        return 1
    fi
    CORE_UPDATED=1
    rm -rf -- "$stage"
    success "Xray 已更新至官方 Latest：$version；原配置和开机启动设置保留。"
}
