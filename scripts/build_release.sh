#!/usr/bin/env bash
set -euo pipefail
RELEASE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$RELEASE_ROOT"
release_version=$(bash socks5.sh --version)
release_name="socks5-router-v$release_version.tar.gz"
release_dir="$RELEASE_ROOT/dist"
mkdir -p -- "$release_dir"
tar --sort=name --mtime='UTC 2026-10-10' --owner=0 --group=0 --numeric-owner \
    --transform='s,^,socks5-router/,' -czf "$release_dir/$release_name" \
    socks5.sh install.sh lib templates \
    README.md docs \
    scripts/build_release.sh
cp -- "$release_dir/$release_name" "$release_dir/socks5-router.tar.gz"
(
    cd -- "$release_dir"
    sha256sum "$release_name" socks5-router.tar.gz > SHA256SUMS
)
printf '已生成 dist/%s、dist/socks5-router.tar.gz 和 dist/SHA256SUMS\n' "$release_name"
