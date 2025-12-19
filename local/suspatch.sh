#!/bin/bash
set -e

# ===== 获取脚本目录 =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ===== 设置自定义参数 =====
echo "===== 欧加真MT6991通用6.6.89 A15 OKI内核本地编译脚本 By Coolapk@cctv18 ====="
echo ">>> 读取用户配置..."
MANIFEST=${MANIFEST:-oppo+oplus+realme}
CUSTOM_SUFFIX="android15-8-g29d86c5fc9dd-abogki428889875-4k"
APPLY_SUSFS="y"
KSU_BRANCH="y"

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
echo "===================="
echo

# ===== 创建工作目录 =====
WORKDIR="$SCRIPT_DIR"
cd "$WORKDIR"

# ===== 安装构建依赖 =====
echo ">>> 安装构建依赖..."
# Function to run a command with sudo if not already root
SU() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

SU apt-mark hold firefox && apt-mark hold libc-bin && apt-mark hold man-db
SU rm -rf /var/lib/man-db/auto-update
SU apt-get update
SU apt-get install --no-install-recommends -y curl bison flex clang binutils dwarves git lld pahole zip perl make gcc python3 python-is-python3 bc libssl-dev libelf-dev cpio xz-utils tar
SU rm -rf ./llvm.sh && wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
SU ./llvm.sh 18 all

# ===== 初始化仓库 =====
echo ">>> 初始化仓库..."
rm -rf kernel_workspace
mkdir kernel_workspace
cd kernel_workspace
git clone --depth=1 https://github.com/cctv18/android_kernel_oneplus_mt6991 -b oneplus/mt6991_v_15.0.2_ace5_ultra_6.6.89 common
echo ">>> 初始化仓库完成"

# ===== 清除 abi 文件、去除 -dirty 后缀 =====
echo ">>> 正在清除 ABI 文件及去除 dirty 后缀..."
rm common/android/abi_gki_protected_exports_* || true

for f in common/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done

# ===== 替换版本后缀 =====
echo ">>> 替换内核版本后缀..."
for f in ./common/scripts/setlocalversion; do
  sed -i "\$s|echo \"\\\$res\"|echo \"-${CUSTOM_SUFFIX}\"|" "$f"
done
sudo sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-'${CUSTOM_SUFFIX}'"/' ./common/arch/arm64/configs/gki_defconfig
sed -i 's/${scm_version}//' ./common/scripts/setlocalversion
echo "CONFIG_LOCALVERSION_AUTO=n" >> ./common/arch/arm64/configs/gki_defconfig

# ===== 拉取 KSU 并设置版本号 =====
if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  echo ">>> 拉取 SukiSU-Ultra 并设置版本..."
  curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/builtin/kernel/setup.sh" | bash -s builtin
  cd KernelSU
  GIT_COMMIT_HASH=$(git rev-parse --short=8 HEAD)
  echo "当前提交哈希: $GIT_COMMIT_HASH"
  echo ">>> 正在获取上游 API 版本信息..."
  for i in {1..3}; do
      KSU_API_VERSION=$(curl -s "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/builtin/kernel/Kbuild" | \
          grep -m1 "KSU_VERSION_API :=" | \
          awk -F'= ' '{print $2}' | \
          tr -d '[:space:]')
      if [ -n "$KSU_API_VERSION" ]; then
          echo "成功获取 API 版本: $KSU_API_VERSION"
          break
      else
          echo "获取失败，重试中 ($i/3)..."
          sleep 1
      fi
  done
  if [ -z "$KSU_API_VERSION" ]; then
      echo -e "无法获取 API 版本，使用默认值 3.1.7..."
      KSU_API_VERSION="3.1.7"
  fi
  export KSU_API_VERSION=$KSU_API_VERSION

  VERSION_DEFINITIONS=$'define get_ksu_version_full\nv\\$1-'"$GIT_COMMIT_HASH"$'@Anatdx\nendef\n\nKSU_VERSION_API := '"$KSU_API_VERSION"$'\nKSU_VERSION_FULL := v'"$KSU_API_VERSION"$'-'"$GIT_COMMIT_HASH"$'@Anatdx'

  echo ">>> 正在修改 kernel/Kbuild 文件..."
  sed -i '/define get_ksu_version_full/,/endef/d' kernel/Kbuild
  sed -i '/KSU_VERSION_API :=/d' kernel/Kbuild
  sed -i '/KSU_VERSION_FULL :=/d' kernel/Kbuild
  awk -v def="$VERSION_DEFINITIONS" '
      /REPO_OWNER :=/ {print; print def; inserted=1; next}
      1
      END {if (!inserted) print def}
  ' kernel/Kbuild > kernel/Kbuild.tmp && mv kernel/Kbuild.tmp kernel/Kbuild

  KSU_VERSION_CODE=$(expr $(git rev-list --count main 2>/dev/null) + 37185 2>/dev/null || echo 114514)
  echo ">>> 修改完成！验证结果："
  echo "------------------------------------------------"
  grep -A10 "REPO_OWNER" kernel/Kbuild | head -n 10
  echo "------------------------------------------------"
  grep "KSU_VERSION_FULL" kernel/Kbuild
  echo ">>> 最终版本字符串: v${KSU_API_VERSION}-${GIT_COMMIT_HASH}@Anatdx"
  echo ">>> Version Code: ${KSU_VERSION_CODE}"
elif [[ "$KSU_BRANCH" == "n" || "$KSU_BRANCH" == "N" ]]; then
  echo ">>> 拉取 KernelSU Next 并设置版本..."
  curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s next-susfs
  cd KernelSU-Next
  KSU_VERSION=$(expr $(curl -sI "https://api.github.com/repos/pershoot/KernelSU-Next/commits?sha=next&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') "+" 10200)
  sed -i "s/DKSU_VERSION=11998/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile
  #为KernelSU Next添加WildKSU管理器支持
  cd ../common/drivers/kernelsu
  wget https://github.com/WildKernels/kernel_patches/raw/refs/heads/main/next/susfs_fix_patches/v1.5.12/fix_apk_sign.c.patch
  patch -p2 -N -F 3 < fix_apk_sign.c.patch || true
elif [[ "$KSU_BRANCH" == "m" || "$KSU_BRANCH" == "M" ]]; then
  echo "正在配置 MKSU (5ec1cff/KernelSU)..."
  curl -LSs "https://raw.githubusercontent.com/5ec1cff/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main
  cd ./KernelSU
  KSU_VERSION=$(expr $(curl -sI "https://api.github.com/repos/5ec1cff/KernelSU/commits?sha=main&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') "+" 30000)
  sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
else
  echo "正在配置原版 KernelSU (tiann/KernelSU)..."
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main
  cd ./KernelSU
  KSU_VERSION=$(expr $(curl -sI "https://api.github.com/repos/tiann/KernelSU/commits?sha=main&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') "+" 30000)
  sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
fi

# ===== 应用 HymoFS 补丁 =====
if [[ "$APPLY_HYMOFS" == "y" || "$APPLY_HYMOFS" == "Y" ]]; then
  echo ">>> 应用 HymoFS 补丁..."
  cd "$WORKDIR/kernel_workspace/common"

  echo "  [*] 注入 HymoFS 代码..."
  patch -p1 < /home/an/hymoworker/HymoFS/patch/hymofs.patch
  
  echo "  [*] HymoFS 代码注入完成！"

  cd "$WORKDIR/kernel_workspace"
fi


# ===== 克隆补丁仓库&应用 SUSFS 补丁 =====
echo ">>> 克隆补丁仓库..."
cd "$WORKDIR/kernel_workspace"
echo ">>> 应用 SUSFS&hook 补丁..."
if [[ "$KSU_BRANCH" == [yY] && "$APPLY_SUSFS" == [yY] ]]; then
  git clone https://github.com/shirkneko/susfs4ksu.git -b gki-android15-6.6
  git clone https://github.com/ShirkNeko/SukiSU_patch.git
  cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch ./common/
  cp ./SukiSU_patch/69_hide_stuff.patch ./common/
  cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
  cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  cd ./common
  patch -p1 < 50_add_susfs_in_gki-android15-6.6.patch || true
  #临时修复 undeclared identifier 'vma' 编译错误：把vma = find_vma(...)替换为struct vm_area_struct *vma = find_vma(...)，解决部分版本源码中vma定义缺失的问题
  sed -i 's|vma = find_vma(mm|struct vm_area_struct *&|' ./fs/proc/task_mmu.c
  patch -p1 -F 3 < 69_hide_stuff.patch || true
elif [[ "$KSU_BRANCH" == [nN] && "$APPLY_SUSFS" == [yY] ]]; then
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6
  #由于KernelSU Next尚未更新并适配susfs 2.0.0，故回退至susfs 1.5.12
  cd susfs4ksu && git checkout f450ec00bf592d080f59b01ff6f9242456c9a427 && cd ..
  git clone https://github.com/WildKernels/kernel_patches.git
  cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch ./common/
  cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
  cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  cp ./kernel_patches/next/scope_min_manual_hooks_v1.5.patch ./common/
  cp ./kernel_patches/69_hide_stuff.patch ./common/
  cd ./common
  patch -p1 < 50_add_susfs_in_gki-android15-6.6.patch || true
  #临时修复 undeclared identifier 'vma' 编译错误：把vma = find_vma(...)替换为struct vm_area_struct *vma = find_vma(...)，解决部分版本源码中vma定义缺失的问题
  sed -i 's|vma = find_vma(mm|struct vm_area_struct *&|' ./fs/proc/task_mmu.c
  patch -p1 -N -F 3 < scope_min_manual_hooks_v1.5.patch || true
  patch -p1 -N -F 3 < 69_hide_stuff.patch || true
elif [[ "$KSU_BRANCH" == [mM] && "$APPLY_SUSFS" == [yY] ]]; then
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6
  git clone https://github.com/ShirkNeko/SukiSU_patch.git
  cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
  # 临时修复：修复susfs补丁日志输出（由于上游KSU把部分Makefile代码移至Kbuild中，而susfs补丁未同步修改，故需修复susfs补丁修补位点）
  PATCH_FILE="./KernelSU/10_enable_susfs_for_ksu.patch"
  if [ -f "$PATCH_FILE" ]; then
    if grep -q "a/kernel/Makefile" "$PATCH_FILE"; then
      echo "检测到旧版 Makefile 补丁代码，正在执行修复..."
      sed -i 's|kernel/Makefile|kernel/Kbuild|g' "$PATCH_FILE"
      sed -i 's|.*compdb.*|@@ -75,4 +75,13 @@ ccflags-y += -DEXPECTED_HASH=\\"$(KSU_EXPECTED_HASH)\\"|' "$PATCH_FILE"
      sed -i 's|^ clean:| ccflags-y += -Wno-strict-prototypes -Wno-int-conversion -Wno-gcc-compat -Wno-missing-prototypes|' "$PATCH_FILE"
      sed -i 's|.*make -C.*| ccflags-y += -Wno-declaration-after-statement -Wno-unused-function|' "$PATCH_FILE"
      echo "补丁修复完成！"
    else
      echo "补丁代码已修复至 Kbuild 或不匹配，跳过修改..."
    fi
  else
    echo "未找到KSU补丁！"
    exit 1
  fi
  cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch ./common/
  cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
  cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  cp ./SukiSU_patch/69_hide_stuff.patch ./common/
  cd ./KernelSU
  patch -p1 < 10_enable_susfs_for_ksu.patch || true
  #为MKSU修正susfs 2.0.0补丁
  wget https://github.com/cctv18/oppo_oplus_realme_sm8750/raw/refs/heads/main/other_patch/mksu_supercalls.patch
  patch -p1 < mksu_supercalls.patch || true
  wget https://github.com/cctv18/oppo_oplus_realme_sm8750/raw/refs/heads/main/other_patch/fix_umount.patch
  patch -p1 < fix_umount.patch || true
  cd ../common
  patch -p1 < 50_add_susfs_in_gki-android15-6.6.patch || true
  #临时修复 undeclared identifier 'vma' 编译错误：把vma = find_vma(...)替换为struct vm_area_struct *vma = find_vma(...)，解决部分版本源码中vma定义缺失的问题
  sed -i 's|vma = find_vma(mm|struct vm_area_struct *&|' ./fs/proc/task_mmu.c
  patch -p1 -N -F 3 < 69_hide_stuff.patch || true
elif [[ "$KSU_BRANCH" == [kK] && "$APPLY_SUSFS" == [yY] ]]; then
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6
  git clone https://github.com/ShirkNeko/SukiSU_patch.git
  cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
  # 临时修复：修复susfs补丁日志输出（由于上游KSU把部分Makefile代码移至Kbuild中，而susfs补丁未同步修改，故需修复susfs补丁修补位点）
  PATCH_FILE="./KernelSU/10_enable_susfs_for_ksu.patch"
  if [ -f "$PATCH_FILE" ]; then
    if grep -q "a/kernel/Makefile" "$PATCH_FILE"; then
      echo "检测到旧版 Makefile 补丁代码，正在执行修复..."
      sed -i 's|kernel/Makefile|kernel/Kbuild|g' "$PATCH_FILE"
      sed -i 's|.*compdb.*|@@ -75,4 +75,13 @@ ccflags-y += -DEXPECTED_HASH=\\"$(KSU_EXPECTED_HASH)\\"|' "$PATCH_FILE"
      sed -i 's|^ clean:| ccflags-y += -Wno-strict-prototypes -Wno-int-conversion -Wno-gcc-compat -Wno-missing-prototypes|' "$PATCH_FILE"
      sed -i 's|.*make -C.*| ccflags-y += -Wno-declaration-after-statement -Wno-unused-function|' "$PATCH_FILE"
      echo "补丁修复完成！"
    else
      echo "补丁代码已修复至 Kbuild 或不匹配，跳过修改..."
    fi
  else
    echo "未找到KSU补丁！"
    exit 1
  fi
  cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch ./common/
  cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
  cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  cp ./SukiSU_patch/69_hide_stuff.patch ./common/
  cd ./KernelSU
  patch -p1 < 10_enable_susfs_for_ksu.patch || true
  wget https://github.com/cctv18/oppo_oplus_realme_sm8750/raw/refs/heads/main/other_patch/fix_umount.patch
  patch -p1 < fix_umount.patch || true
  cd ../common
  patch -p1 < 50_add_susfs_in_gki-android15-6.6.patch || true
  #临时修复 undeclared identifier 'vma' 编译错误：把vma = find_vma(...)替换为struct vm_area_struct *vma = find_vma(...)，解决部分版本源码中vma定义缺失的问题
  sed -i 's|vma = find_vma(mm|struct vm_area_struct *&|' ./fs/proc/task_mmu.c
  patch -p1 -N -F 3 < 69_hide_stuff.patch || true
else
  echo ">>> 未开启susfs，跳过susfs补丁配置..."
fi

echo ">>> susfs补丁配置完成。"