#!/usr/bin/env bash
# Chinese interactive SOCKS5 manager. Keep this file beside the Python files.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    if [[ ${EUID} -ne 0 ]]; then
        printf '%s\n' '请先安装 Python 3.9+，或使用 sudo bash socks5.sh。' >&2
        exit 1
    fi
    printf '%s\n' '正在安装管理脚本所需的 Python 3 和 CA 证书……'
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y python3 ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 ca-certificates
    else
        printf '%s\n' '未识别包管理器，请手动安装 Python 3.9+ 和 ca-certificates。' >&2
        exit 1
    fi
fi
exec python3 "$SCRIPT_DIR/socks5.py" "$@"
