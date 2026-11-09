#!/usr/bin/env bash
# Обновить SHA256 install_amneziawg.sh в autodeploy.sh (запускать после любой правки установщика).
set -euo pipefail
cd "$(dirname "$0")/.."
sha=$(sha256sum install_amneziawg.sh | awk '{print $1}')
sed -i -E "s/^INSTALLER_SHA256=\"[^\"]*\"/INSTALLER_SHA256=\"${sha}\"/" autodeploy.sh
grep -q "^INSTALLER_SHA256=\"${sha}\"" autodeploy.sh
echo "autodeploy.sh: INSTALLER_SHA256=${sha}"
