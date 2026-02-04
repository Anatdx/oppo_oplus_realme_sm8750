#!/bin/bash
set -e
exec > >(tee buildlog.txt)
exec 2>&1

IS_MACOS=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ===== 仅允许 Linux 运行（容器内）=====
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "错误: 请使用包装脚本在 OrbStack 容器内运行"
    exit 1
fi

# ===== 设置自定义参数 =====
echo "===== 欧加真MT6991通用6.6.89 A15 OKI内核本地编译脚本 By Coolapk@cctv18 ====="
echo ">>> 读取用户配置..."
MANIFEST=${MANIFEST:-oppo+oplus+realme}
read -p "请输入自定义内核后缀（默认：android15-8-g29d86c5fc9dd-abogki428889875-4k）: " CUSTOM_SUFFIX
CUSTOM_SUFFIX=${CUSTOM_SUFFIX:-android15-8-g29d86c5fc9dd-abogki428889875-4k}
read -p "是否启用susfs？(y/n，默认：n): " APPLY_SUSFS
APPLY_SUSFS=${APPLY_SUSFS:-n}
read -p "是否启用 KPM？(y/n，默认：n): " USE_PATCH_LINUX
USE_PATCH_LINUX=${USE_PATCH_LINUX:-n}
read -p "KSU分支版本(y=SukiSU Ultra, n=KernelSU Next, m=MKSU, k=KSU, 默认：y): " KSU_BRANCH
KSU_BRANCH=${KSU_BRANCH:-y}
read -p "是否应用 lz4 1.10.0 & zstd 1.5.7 补丁？(y/n，默认：y): " APPLY_LZ4
APPLY_LZ4=${APPLY_LZ4:-y}
read -p "是否应用 lz4kd 补丁？(y/n，默认：n): " APPLY_LZ4KD
APPLY_LZ4KD=${APPLY_LZ4KD:-n}
read -p "是否启用网络功能增强优化配置？(y/n，默认：n): " APPLY_BETTERNET
APPLY_BETTERNET=${APPLY_BETTERNET:-n}
read -p "是否添加 BBR 等一系列拥塞控制算法？(y添加/n禁用/d默认，默认：n): " APPLY_BBR
APPLY_BBR=${APPLY_BBR:-n}
read -p "是否启用ADIOS调度器？(y/n，默认：y): " APPLY_ADIOS
APPLY_ADIOS=${APPLY_ADIOS:-y}
read -p "是否启用Re-Kernel？(y/n，默认：y): " APPLY_REKERNEL
APPLY_REKERNEL=${APPLY_REKERNEL:-y}
read -p "是否启用内核级基带保护？(y/n，默认：y): " APPLY_BBG
APPLY_BBG=${APPLY_BBG:-y}
read -p "是否启用 HymoFS？(y/n，默认：y): " APPLY_HYMOFS
APPLY_HYMOFS=${APPLY_HYMOFS:-y}

if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  KSU_TYPE="SukiSU Ultra"
elif [[ "$KSU_BRANCH" == "n" || "$KSU_BRANCH" == "N" ]]; then
  KSU_TYPE="KernelSU Next"
elif [[ "$KSU_BRANCH" == "m" || "$KSU_BRANCH" == "M" ]]; then
  KSU_TYPE="MKSU"
else
  KSU_TYPE="KernelSU"
fi

echo
echo "===== 配置信息 ====="
echo "适用机型: $MANIFEST"
echo "自定义内核后缀: -$CUSTOM_SUFFIX"
echo "KSU分支版本: $KSU_TYPE"
echo "启用susfs: $APPLY_SUSFS"
echo "启用 KPM: $USE_PATCH_LINUX"
echo "应用 lz4&zstd 补丁: $APPLY_LZ4"
echo "应用 lz4kd 补丁: $APPLY_LZ4KD"
echo "应用网络功能增强优化配置: $APPLY_BETTERNET"
echo "应用 BBR 等算法: $APPLY_BBR"
echo "启用ADIOS调度器: $APPLY_ADIOS"
echo "启用Re-Kernel: $APPLY_REKERNEL"
echo "启用内核级基带保护: $APPLY_BBG"
echo "启用 HymoFS: $APPLY_HYMOFS"
echo "===================="
echo

# ===== 创建工作目录 =====
WORKDIR="$SCRIPT_DIR"
cd "$WORKDIR"

# ===== 安装构建依赖 =====
echo ">>> 安装构建依赖..."
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请以 root 运行（使用包装脚本启动）"
    exit 1
fi

apt-mark hold firefox && apt-mark hold libc-bin && apt-mark hold man-db
rm -rf /var/lib/man-db/auto-update
apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 update
apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 install --fix-missing --no-install-recommends -y \
  curl bison flex clang binutils dwarves git lld pahole zip perl make gcc \
  python3 python-is-python3 bc libssl-dev libelf-dev zlib1g-dev cpio xz-utils tar \
  patch wget device-tree-compiler libfdt-dev libyaml-dev pkg-config \
  lsb-release software-properties-common gnupg unzip rcs
rm -rf ./llvm.sh && wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
./llvm.sh 18 all

SED_INPLACE="sed -i"

# ===== 初始化仓库 =====
echo ">>> 初始化仓库..."
rm -rf kernel_workspace
mkdir kernel_workspace
cd kernel_workspace
git clone --depth=1 https://github.com/cctv18/android_kernel_oneplus_mt6991 -b oneplus/mt6991_v_15.0.2_ace5_ultra_6.6.89 common
echo ">>> 初始化仓库完成"

# ===== 修复 dtc 链接 (undefined symbol: dt_to_yaml，避免依赖 libyaml) =====
echo ">>> 应用 dtc NO_YAML 补丁..."
DTC_MKF="common/scripts/dtc/Makefile"
if [ -f "$DTC_MKF" ] && ! grep -q 'HOSTCFLAGS_dtc.o := -DNO_YAML' "$DTC_MKF"; then
  $SED_INPLACE '/^# Generated files need one more search path/i\
# Ensure dtc.o is built with NO_YAML so dt_to_yaml is not referenced (avoids libyaml dependency)\
HOSTCFLAGS_dtc.o := -DNO_YAML
' "$DTC_MKF"
  echo ">>> dtc 补丁已应用"
fi

# ===== 清除 abi 文件、去除 -dirty 后缀 =====
echo ">>> 正在清除 ABI 文件及去除 dirty 后缀..."
rm -f common/android/abi_gki_protected_exports_* || true

SETLOCALVERSION_FILE="common/scripts/setlocalversion"
if [ -f "$SETLOCALVERSION_FILE" ]; then
  $SED_INPLACE 's/ -dirty//g' "$SETLOCALVERSION_FILE"
  $SED_INPLACE '$a\
res=$(echo "$res" | sed '\''s/-dirty//g'\'')
' "$SETLOCALVERSION_FILE"
fi

# ===== 替换版本后缀 =====
echo ">>> 替换内核版本后缀..."
if [ -f "$SETLOCALVERSION_FILE" ]; then
  $SED_INPLACE "\$s|echo \"\\\$res\"|echo \"-${CUSTOM_SUFFIX}\"|" "$SETLOCALVERSION_FILE"
  $SED_INPLACE 's/${scm_version}//' "$SETLOCALVERSION_FILE"
fi
$SED_INPLACE 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-'${CUSTOM_SUFFIX}'"/' ./common/arch/arm64/configs/gki_defconfig
echo "CONFIG_LOCALVERSION_AUTO=n" >> ./common/arch/arm64/configs/gki_defconfig

# ===== 拉取 KSU 并设置版本号 =====
if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  echo ">>> 使用本地 YukiSU 并设置版本..."
  YUKISU_PATH="/Volumes/Workspace/YukiSU"
  if [ ! -d "$YUKISU_PATH" ]; then
    echo "错误: 未找到本地 YukiSU 目录: $YUKISU_PATH"
    exit 1
  fi
  if [ ! -d "$YUKISU_PATH/kernel" ]; then
    echo "错误: 未找到 YukiSU kernel 目录: $YUKISU_PATH/kernel"
    exit 1
  fi

  cd "$WORKDIR/kernel_workspace/common"
  DRIVER_DIR="$WORKDIR/kernel_workspace/common/drivers"

  echo ">>> 拷贝 YukiSU kernel 目录到 drivers/kernelsu..."
  rm -rf "$DRIVER_DIR/kernelsu"
  cp -r "$YUKISU_PATH/kernel" "$DRIVER_DIR/kernelsu"

  if ! grep -q "kernelsu" "$DRIVER_DIR/Makefile"; then
    echo "obj-\$(CONFIG_KSU) += kernelsu/" >> "$DRIVER_DIR/Makefile"
    echo ">>> 已添加到 Makefile"
  fi

  if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"; then
    $SED_INPLACE '/endmenu/i\
source "drivers/kernelsu/Kconfig"
' "$DRIVER_DIR/Kconfig"
    echo ">>> 已添加到 Kconfig"
  fi

  cd "$YUKISU_PATH"
  GIT_COMMIT_HASH=$(git rev-parse --short=8 HEAD)
  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

  if [ -f "kernel/Kbuild" ]; then
    KSU_API_VERSION=$(grep -m1 "^KSU_VERSION_API :=" kernel/Kbuild | \
        awk -F':= ' '{print $2}' | \
        tr -d '[:space:]')
  fi

  if [ -z "$KSU_API_VERSION" ]; then
    echo ">>> 警告: 无法从 Kbuild 读取 API 版本，使用默认值 1.3.0"
    KSU_API_VERSION="1.3.0"
  else
    echo ">>> 成功获取 API 版本: $KSU_API_VERSION"
  fi

  VERSION_DEFINITIONS=$'define get_ksu_version_full\nv\\$1-'"$GIT_COMMIT_HASH"$'@'"$GIT_BRANCH"$'\nendef\n\nKSU_VERSION_API := '"$KSU_API_VERSION"$'\nKSU_VERSION_FULL := v'"$KSU_API_VERSION"$'-'"$GIT_COMMIT_HASH"$'@'"$GIT_BRANCH"$''

  KBUILD_FILE="$DRIVER_DIR/kernelsu/Kbuild"
  $SED_INPLACE '/define get_ksu_version_full/,/endef/d' "$KBUILD_FILE"
  $SED_INPLACE '/KSU_VERSION_API :=/d' "$KBUILD_FILE"
  $SED_INPLACE '/KSU_VERSION_FULL :=/d' "$KBUILD_FILE"
  awk -v def="$VERSION_DEFINITIONS" '
      /REPO_OWNER :=/ {print; print def; inserted=1; next}
      1
      END {if (!inserted) print def}
  ' "$KBUILD_FILE" > "$KBUILD_FILE.tmp" && \
      mv "$KBUILD_FILE.tmp" "$KBUILD_FILE"

  KSU_LOCAL_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  KSU_VERSION=$(expr 10000 + ${KSU_LOCAL_VERSION} - 1135 2>/dev/null || echo 10000)
  KSU_VERSION_FULL="v${KSU_API_VERSION}-${GIT_COMMIT_HASH}@${GIT_BRANCH}"

  echo ">>> YukiSU 版本信息："
  echo "  API 版本: ${KSU_API_VERSION}"
  echo "  版本代码: ${KSU_VERSION}"
  echo "  完整版本: ${KSU_VERSION_FULL}"
  echo "  提交哈希: ${GIT_COMMIT_HASH}"
  echo "  分支: ${GIT_BRANCH}"

  cd "$WORKDIR/kernel_workspace"
elif [[ "$KSU_BRANCH" == "n" || "$KSU_BRANCH" == "N" ]]; then
  echo ">>> 拉取 KernelSU Next 并设置版本..."
  curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s next-susfs
  cd KernelSU-Next
  KSU_VERSION=$(expr $(curl -sI "https://api.github.com/repos/pershoot/KernelSU-Next/commits?sha=next&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') "+" 10200)
  $SED_INPLACE "s/DKSU_VERSION=11998/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile
  cd ../common/drivers/kernelsu
  wget https://github.com/WildKernels/kernel_patches/raw/refs/heads/main/next/susfs_fix_patches/v1.5.12/fix_apk_sign.c.patch
  patch -p2 -N -F 3 < fix_apk_sign.c.patch || true
  cd "$WORKDIR/kernel_workspace"
elif [[ "$KSU_BRANCH" == "m" || "$KSU_BRANCH" == "M" ]]; then
  echo "正在配置 MKSU (5ec1cff/KernelSU)..."
  curl -LSs "https://raw.githubusercontent.com/5ec1cff/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main
  cd ./KernelSU
  KSU_VERSION=$(expr $(curl -sI "https://api.github.com/repos/5ec1cff/KernelSU/commits?sha=main&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') "+" 30000)
  $SED_INPLACE "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
  cd "$WORKDIR/kernel_workspace"
else
  echo "正在配置原版 KernelSU (tiann/KernelSU)..."
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main
  cd ./KernelSU
  KSU_VERSION=$(expr $(curl -sI "https://api.github.com/repos/tiann/KernelSU/commits?sha=main&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') "+" 30000)
  $SED_INPLACE "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
  cd "$WORKDIR/kernel_workspace"
fi


# ===== 应用 LZ4 & ZSTD 补丁 =====
if [[ "$APPLY_LZ4" == "y" || "$APPLY_LZ4" == "Y" ]]; then
  echo ">>> 正在添加lz4 1.10.0 & zstd 1.5.7补丁..."
  git clone https://github.com/cctv18/oppo_oplus_realme_sm8750.git
  cp ./oppo_oplus_realme_sm8750/zram_patch/001-lz4.patch ./common/
  cp ./oppo_oplus_realme_sm8750/zram_patch/001-lz4-clearMake.patch ./common/
  cp ./oppo_oplus_realme_sm8750/zram_patch/lz4armv8.S ./common/lib
  cp ./oppo_oplus_realme_sm8750/zram_patch/002-zstd.patch ./common/
  cd "$WORKDIR/kernel_workspace/common"
  git apply -p1 < 001-lz4.patch || true
  git apply -p1 < 001-lz4-clearMake.patch || true
  patch -p1 < 002-zstd.patch || true
  cd "$WORKDIR/kernel_workspace"
else
  echo ">>> 跳过 LZ4&ZSTD 补丁..."
  cd "$WORKDIR/kernel_workspace"
fi

# ===== 应用 LZ4KD 补丁 =====
if [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  echo ">>> 应用 LZ4KD 补丁..."
  if [ ! -d "SukiSU_patch" ]; then
    git clone https://github.com/ShirkNeko/SukiSU_patch.git
  fi
  cp -r ./SukiSU_patch/other/zram/lz4k/include/linux/* ./common/include/linux/
  cp -r ./SukiSU_patch/other/zram/lz4k/lib/* ./common/lib
  cp -r ./SukiSU_patch/other/zram/lz4k/crypto/* ./common/crypto
  cp ./SukiSU_patch/other/zram/zram_patch/6.6/lz4kd.patch ./common/
  cd "$WORKDIR/kernel_workspace/common"
  patch -p1 -F 3 < lz4kd.patch || true
  cd "$WORKDIR/kernel_workspace"
else
  echo ">>> 跳过 LZ4KD 补丁..."
  cd "$WORKDIR/kernel_workspace"
fi


# ===== 添加 defconfig 配置项 =====
echo ">>> 添加 defconfig 配置项..."
DEFCONFIG_FILE=./common/arch/arm64/configs/gki_defconfig

# 写入通用 SUSFS/KSU 配置
echo "CONFIG_KSU=y" >> "$DEFCONFIG_FILE"
if [[ "$APPLY_SUSFS" == [yY] ]]; then
  echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y" >> "$DEFCONFIG_FILE"
else
  echo "CONFIG_KSU_SUSFS=n" >> "$DEFCONFIG_FILE"
fi
#添加对 Mountify (backslashxx/mountify) 模块的支持
echo "CONFIG_TMPFS_XATTR=y" >> "$DEFCONFIG_FILE"
echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$DEFCONFIG_FILE"

# ===== 应用 HymoFS 补丁 =====
if [[ "$APPLY_HYMOFS" == "y" || "$APPLY_HYMOFS" == "Y" ]]; then
  echo ">>> 应用 HymoFS 补丁..."
  cd "$WORKDIR/kernel_workspace/common"

  HYMOFS_PATCH="/Volumes/Workspace/HymoFS/patch/hymofs.patch"
  if [ ! -f "$HYMOFS_PATCH" ]; then
    echo "错误: 未找到本地 HymoFS 补丁文件: $HYMOFS_PATCH"
    exit 1
  fi

  echo "  [*] 使用本地 HymoFS 补丁: $HYMOFS_PATCH"
  
  # 检查是否已经应用过补丁
  if [ -f "fs/hymofs.c" ]; then
    echo "警告: fs/hymofs.c 已存在，补丁可能已应用"
  fi
  
  # 应用补丁
  if patch -p1 -F 3 < "$HYMOFS_PATCH"; then
    echo "  [*] HymoFS 补丁应用成功！"
  else
    echo "  [!] HymoFS 补丁应用失败，请检查错误日志"
    exit 1
  fi

cd "$WORKDIR/kernel_workspace"
  if ! grep -q "CONFIG_HYMOFS=y" "$DEFCONFIG_FILE"; then
    echo "" >> "$DEFCONFIG_FILE"
    echo "# HymoFS Support" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_REVERSE_LOOKUP=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_FORWARD_REDIRECT=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_HIDE_ENTRIES=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_INJECT_ENTRIES=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_STAT_SPOOF=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_XATTR_FILTER=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_UNAME_SPOOF=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_CMDLINE_SPOOF=y" >> "$DEFCONFIG_FILE"
    echo "CONFIG_HYMOFS_DEBUG=y" >> "$DEFCONFIG_FILE"
    echo "  [*] 已添加 HymoFS 配置项到 defconfig"
  else
    echo "  [*] defconfig 已包含 CONFIG_HYMOFS，跳过"
  fi

  echo "  [*] HymoFS 代码注入完成！"
  cd "$WORKDIR/kernel_workspace"
fi


# 开启O2编译优化配置
echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DEFCONFIG_FILE"
#跳过将uapi标准头安装到 usr/include 目录的不必要操作，节省编译时间
echo "CONFIG_HEADERS_INSTALL=n" >> "$DEFCONFIG_FILE"

# 仅在启用了 KPM 时添加 KPM 支持
if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]]; then
  echo "CONFIG_KPM=y" >> "$DEFCONFIG_FILE"
fi

# ===== 签名配置 =====
SIGNING_KEY_PATH="$HOME/hymoworker/signing_key.pem"
if [ -f "$SIGNING_KEY_PATH" ]; then
  echo ">>> 添加内核签名配置..."
  echo "CONFIG_MODULE_SIG=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_MODULE_SIG_FORCE=n" >> "$DEFCONFIG_FILE"
  echo "CONFIG_MODULE_SIG_ALL=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_MODULE_SIG_SHA512=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_MODULE_SIG_HASH=\"sha512\"" >> "$DEFCONFIG_FILE"
  echo "CONFIG_MODULE_SIG_KEY=\"certs/signing_key.pem\"" >> "$DEFCONFIG_FILE"
  echo "CONFIG_SYSTEM_TRUSTED_KEYS=\"certs/signing_key_cert.pem\"" >> "$DEFCONFIG_FILE"
fi

# 仅在启用了 LZ4KD 补丁时添加相关算法支持
if [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  cat >> "$DEFCONFIG_FILE" <<EOF
CONFIG_ZSMALLOC=y
CONFIG_CRYPTO_LZ4HC=y
CONFIG_CRYPTO_LZ4K=y
CONFIG_CRYPTO_LZ4KD=y
CONFIG_CRYPTO_842=y
EOF

fi

# ===== 启用网络功能增强优化配置 =====
if [[ "$APPLY_BETTERNET" == "y" || "$APPLY_BETTERNET" == "Y" ]]; then
  echo ">>> 正在启用网络功能增强优化配置..."
  echo "CONFIG_BPF_STREAM_PARSER=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_NETFILTER_XT_SET=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_MAX=65534" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_BITMAP_IP=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_BITMAP_IPMAC=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_BITMAP_PORT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_IP=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_IPMARK=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_IPPORT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_IPPORTIP=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_IPPORTNET=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_IPMAC=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_MAC=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_NETPORTNET=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_NET=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_NETNET=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_NETPORT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_HASH_NETIFACE=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP_SET_LIST_SET=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP6_NF_NAT=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_IP6_NF_TARGET_MASQUERADE=y" >> "$DEFCONFIG_FILE"
  #由于部分机型的vintf兼容性检测规则，在开启CONFIG_IP6_NF_NAT后开机会出现"您的设备内部出现了问题。请联系您的设备制造商了解详情。"的提示，故添加一个配置修复补丁，在编译内核时隐藏CONFIG_IP6_NF_NAT=y但不影响对应功能编译
  cd common
  curl -L -o config.patch https://github.com/cctv18/oppo_oplus_realme_sm8750/raw/refs/heads/main/other_patch/config.patch
  patch -p1 -F 3 < config.patch || true
  cd ..
fi

# ===== 添加 BBR 等一系列拥塞控制算法 =====
if [[ "$APPLY_BBR" == "y" || "$APPLY_BBR" == "Y" || "$APPLY_BBR" == "d" || "$APPLY_BBR" == "D" ]]; then
  echo ">>> 正在添加 BBR 等一系列拥塞控制算法..."
  echo "CONFIG_TCP_CONG_ADVANCED=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_TCP_CONG_CUBIC=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_TCP_CONG_VEGAS=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_TCP_CONG_NV=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_TCP_CONG_WESTWOOD=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_TCP_CONG_HTCP=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_TCP_CONG_BRUTAL=y" >> "$DEFCONFIG_FILE"
  if [[ "$APPLY_BBR" == "d" || "$APPLY_BBR" == "D" ]]; then
    echo "CONFIG_DEFAULT_TCP_CONG=bbr" >> "$DEFCONFIG_FILE"
  else
    echo "CONFIG_DEFAULT_TCP_CONG=cubic" >> "$DEFCONFIG_FILE"
  fi
fi

# ===== 启用ADIOS调度器 =====
if [[ "$APPLY_ADIOS" == "y" || "$APPLY_ADIOS" == "Y" ]]; then
  echo ">>> 正在启用ADIOS调度器..."
  echo "CONFIG_MQ_IOSCHED_ADIOS=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y" >> "$DEFCONFIG_FILE"
fi

# ===== 启用Re-Kernel =====
if [[ "$APPLY_REKERNEL" == "y" || "$APPLY_REKERNEL" == "Y" ]]; then
  echo ">>> 正在启用Re-Kernel..."
  echo "CONFIG_REKERNEL=y" >> "$DEFCONFIG_FILE"
fi

# ===== 启用内核级基带保护 =====
if [[ "$APPLY_BBG" == "y" || "$APPLY_BBG" == "Y" ]]; then
  echo ">>> 正在启用内核级基带保护..."
  echo "CONFIG_BBG=y" >> "$DEFCONFIG_FILE"
  cd ./common/security
  curl -L -o master.zip https://github.com/cctv18/Baseband-guard/archive/refs/heads/master.zip
  unzip -q master.zip
  mv "Baseband-guard-master" baseband-guard
  printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> ./Makefile
  $SED_INPLACE '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/lockdown/lockdown,baseband_guard/ } }' ./Kconfig
  awk '
  /endmenu/ { last_endmenu_line = NR }
  { lines[NR] = $0 }
  END {
    for (i=1; i<=NR; i++) {
      if (i == last_endmenu_line) {
        sub(/endmenu/, "", lines[i]);
        print lines[i] "source \"security/baseband-guard/Kconfig\""
        print ""
        print "endmenu"
      } else {
          print lines[i]
      }
    }
  }
  ' ./Kconfig > Kconfig.tmp && mv Kconfig.tmp ./Kconfig
  $SED_INPLACE 's/selinuxfs.o //g' "./selinux/Makefile"
  $SED_INPLACE 's/hooks.o //g' "./selinux/Makefile"
  cat "./baseband-guard/sepatch.txt" >> "./selinux/Makefile"
  cd ../../
fi

# ===== 禁用 defconfig 检查 =====
echo ">>> 禁用 defconfig 检查..."
$SED_INPLACE 's/check_defconfig//' ./common/build.config.gki

# ===== 修复 KernelSU 编译错误 =====
echo ">>> 修复 KernelSU ksud.c 编译错误..."
if [ -f "./common/drivers/kernelsu/ksud.c" ]; then
  $SED_INPLACE 's/#if defined(CONFIG_KSU_MANUAL_HOOK)/#if 1/' ./common/drivers/kernelsu/ksud.c || true
fi

# ===== 替换签名证书 =====
if [ -f "$SIGNING_KEY_PATH" ]; then
  echo ">>> 替换签名证书..."
  mkdir -p ./common/certs
  cp "$SIGNING_KEY_PATH" ./common/certs/signing_key.pem
  # 生成 PEM 格式的证书用于 SYSTEM_TRUSTED_KEYS
  openssl x509 -in "$SIGNING_KEY_PATH" -outform PEM -out ./common/certs/signing_key_cert.pem
else
  echo ">>> 未找到自定义证书，使用默认证书"
fi

# ===== 获取 CPU 核心数 =====
if [ "$IS_MACOS" -eq 1 ]; then
    CPU_CORES=$(sysctl -n hw.ncpu)
else
    CPU_CORES=$(nproc)
fi
echo ">>> 检测到 CPU 核心数: $CPU_CORES"

# ===== 设置 LLVM 工具链 =====
CLANG_PATH="$(command -v clang || true)"
LLD_PATH="$(command -v ld.lld || true)"
# AR 必须指向 archiver(ar)，不能为空，否则 Make 会误把 "rcs" 当命令执行（RCS 版本控制）
# 使用 || true 避免 set -e 在未找到 llvm-ar 时直接退出，以便回退到 ar
AR_PATH="$(command -v llvm-ar 2>/dev/null)" || true
[ -z "$AR_PATH" ] && AR_PATH="$(command -v ar 2>/dev/null)"
[ -z "$AR_PATH" ] && { echo "错误: 未找到 llvm-ar 或 ar"; exit 1; }
NM_PATH="$(command -v llvm-nm || true)"
OBJCOPY_PATH="$(command -v llvm-objcopy || true)"
OBJDUMP_PATH="$(command -v llvm-objdump || true)"
STRIP_PATH="$(command -v llvm-strip || true)"
READELF_PATH="$(command -v llvm-readelf || true)"
SIZE_PATH="$(command -v llvm-size || true)"
ADDR2LINE_PATH="$(command -v llvm-addr2line || true)"
if [ -n "$CLANG_PATH" ]; then
    echo ">>> 使用系统 LLVM 工具链: $(clang --version | head -1)"
else
    echo ">>> 未找到 clang，请检查依赖安装"
fi


# ===== 编译内核 =====
echo ">>> 开始编译内核..."
cd common

# macOS 上使用 ccache 可能不可用，先检查
if command -v ccache &> /dev/null; then
    CCACHE_PREFIX="ccache "
    echo ">>> 使用 ccache 加速编译"
else
    CCACHE_PREFIX=""
    echo ">>> 未安装 ccache，跳过缓存加速 (可选安装: brew install ccache)"
fi

HOSTCFLAGS="-I${WORKDIR}/kernel_workspace/common/out/include"
# 强制 host 工具（如 resolve_btfids）用 ld.lld 链接，避免与系统 ld 不兼容
KBUILD_HOSTLDFLAGS="-fuse-ld=lld"

make -j${CPU_CORES} V=0 \
    LLVM=1 \
    LLVM_IAS=1 \
    ARCH=arm64 \
    CC="${CCACHE_PREFIX}${CLANG_PATH}" \
    LD="${LLD_PATH}" \
    AR="${AR_PATH}" \
    NM="${NM_PATH}" \
    OBJCOPY="${OBJCOPY_PATH}" \
    OBJDUMP="${OBJDUMP_PATH}" \
    STRIP="${STRIP_PATH}" \
    READELF="${READELF_PATH}" \
    SIZE="${SIZE_PATH}" \
    ADDR2LINE="${ADDR2LINE_PATH}" \
    HOSTCC="${CCACHE_PREFIX}${CLANG_PATH}" \
           HOSTCFLAGS="${HOSTCFLAGS}" \
           KBUILD_HOSTCFLAGS="${HOSTCFLAGS}" \
           KBUILD_HOSTLDFLAGS="${KBUILD_HOSTLDFLAGS}" \
           HOST_EXTRACFLAGS="${HOSTCFLAGS}" \
    RCS=":" \
    HOSTLD="${LLD_PATH}" \
    HOSTAR="${AR_PATH}" \
    HOSTNM="${NM_PATH}" \
    HOSTOBJCOPY="${OBJCOPY_PATH}" \
    HOSTOBJDUMP="${OBJDUMP_PATH}" \
    O=out \
    KCFLAGS+=-O2 \
    KCFLAGS+=-Wno-error \
    gki_defconfig \
    all

echo ">>> 内核编译成功！"

# ===== 选择使用 patch_linux (KPM补丁)=====
OUT_DIR="$WORKDIR/kernel_workspace/common/out/arch/arm64/boot"
if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]]; then
  echo ">>> 使用 patch_linux 工具处理输出..."
  cd "$OUT_DIR"
  curl -L -o patch_linux https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download/patch_linux
  chmod +x patch_linux
  ./patch_linux
  rm -f Image
  mv oImage Image
  echo ">>> 已成功打上KPM补丁"
else
  echo ">>> 跳过 patch_linux 操作"
fi

# ===== 克隆并打包 AnyKernel3 =====
cd "$WORKDIR/kernel_workspace"
echo ">>> 克隆 AnyKernel3 项目..."
git clone https://github.com/cctv18/AnyKernel3 --depth=1

echo ">>> 清理 AnyKernel3 Git 信息..."
rm -rf ./AnyKernel3/.git

echo ">>> 拷贝内核镜像到 AnyKernel3 目录..."
cp "$OUT_DIR/Image" ./AnyKernel3/

echo ">>> 进入 AnyKernel3 目录并打包 zip..."
cd "$WORKDIR/kernel_workspace/AnyKernel3"

# ===== 如果启用 lz4kd，则下载 zram.zip 并放入当前目录 =====
if [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  curl -L -o zram.zip https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8750/refs/heads/main/zram.zip
fi

# ===== 生成 ZIP 文件名 =====
ZIP_NAME="Anykernel3-${MANIFEST}"

if [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-lz4kd"
fi
if [[ "$APPLY_LZ4" == "y" || "$APPLY_LZ4" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-lz4-zstd"
fi
if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-kpm"
fi
if [[ "$APPLY_BBR" == "y" || "$APPLY_BBR" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-bbr"
fi
if [[ "$APPLY_ADIOS" == "y" || "$APPLY_ADIOS" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-adios"
fi
if [[ "$APPLY_REKERNEL" == "y" || "$APPLY_REKERNEL" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-rek"
fi
if [[ "$APPLY_BBG" == "y" || "$APPLY_BBG" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-bbg"
fi

ZIP_NAME="${ZIP_NAME}-v$(date +%Y%m%d).zip"

# ===== 打包 ZIP 文件，包括 zram.zip（如果存在） =====
echo ">>> 打包文件: $ZIP_NAME"
zip -r "../$ZIP_NAME" ./*

ZIP_PATH="$(realpath "../$ZIP_NAME" 2>/dev/null || echo "$(cd .. && pwd)/$ZIP_NAME")"
echo ">>> 打包完成 文件所在目录: $ZIP_PATH"
