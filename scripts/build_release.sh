#!/usr/bin/env bash
set -euo pipefail
RELEASE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$RELEASE_ROOT"
release_version=$(bash socks5.sh --version)
release_name="socks5-router-v$release_version.tar.gz"
tar --sort=name --mtime='UTC 2026-10-10' --owner=0 --group=0 --numeric-owner \
    --transform='s,^,socks5-router/,' -czf "$release_name" \
    socks5.sh install.sh lib/config.sh templates/xray.json templates/render.jq \
    README.md examples/server-a.json examples/server-b.json \
    scripts/build_release.sh
cp -- "$release_name" socks5-router.tar.gz
sha256sum "$release_name" socks5-router.tar.gz > SHA256SUMS
printf '已生成 %s、socks5-router.tar.gz 和 SHA256SUMS\n' "$release_name"
