#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="builder_6.6.89_mtk_macos.sh"

if ! command -v orb &> /dev/null; then
  echo "错误: 未检测到 orb，请先启动 OrbStack"
  exit 1
fi

ORBSTACK_MACHINE=${ORBSTACK_MACHINE:-ubuntu}
ORBSTACK_USER=${ORBSTACK_USER:-root}

ARGS=""
if [ "$#" -gt 0 ]; then
  ARGS="$(printf '%q ' "$@")"
fi

echo ">>> 使用 OrbStack 机器执行: ${ORBSTACK_MACHINE} (user: ${ORBSTACK_USER})"
echo ">>> 清理 kernel_workspace（仅在宿主机）..."
sudo rm -rf "${SCRIPT_DIR}/kernel_workspace"
exec orb -m "${ORBSTACK_MACHINE}" -u "${ORBSTACK_USER}" \
  env IN_ORBSTACK=1 \
  bash -lc "cd \"${SCRIPT_DIR}\" && ./\"${SCRIPT_NAME}\" ${ARGS}"
