#!/bin/bash
# =============================================================================
# setup_openeuler_deps.sh
# 在 openEuler 上安装 Mooncake 编译所需的系统依赖（单一脚本版）
#
# 用法（在 openEuler 上）：
#   sudo bash setup_openeuler_deps.sh
# 加 -y 跳过交互确认（可选）
# =============================================================================

set -uo pipefail

GREEN="\033[0;32m"; BLUE="\033[0;34m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"

print_section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
print_ok()      { echo -e "${GREEN}✓ $1${NC}"; }
print_warn()    { echo -e "${YELLOW}! $1${NC}"; }
print_err()     { echo -e "${RED}✗ $1${NC}"; }

# ---------- 0) 参数处理 ----------
SKIP_CONFIRM=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) SKIP_CONFIRM=true ;;
        -h|--help)
            echo "openEuler Mooncake 依赖安装脚本"
            echo "用法: sudo bash setup_openeuler_deps.sh [-y]"
            exit 0
            ;;
    esac
done

# ---------- 1) root 检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    print_err "需要 root 权限，请用: sudo bash setup_openeuler_deps.sh"
    exit 1
fi

if [ "$SKIP_CONFIRM" = false ]; then
    read -p "即将安装系统依赖，是否继续? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n "$REPLY" ]]; then
        echo "已取消。"
        exit 0
    fi
fi

# ---------- 2) 检测包管理器（dnf / yum）----------
PKG_MGR=""
command -v dnf >/dev/null 2>&1 && PKG_MGR=dnf
[ -z "$PKG_MGR" ] && command -v yum >/dev/null 2>&1 && PKG_MGR=yum
if [ -z "$PKG_MGR" ]; then
    print_err "未找到 dnf/yum，本脚本仅适用于 openEuler/RHEL 系。"
    exit 1
fi
print_ok "使用包管理器: ${PKG_MGR}"

# ---------- 3) 刷新软件源 ----------
print_section "刷新软件源"
${PKG_MGR} makecache -y || ${PKG_MGR} makecache || true

# ---------- 4) 安装核心编译依赖（openEuler 正确包名）----------
print_section "安装核心编译依赖"
CORE_PACKAGES=(
    gcc gcc-c++ make cmake ninja-build git wget unzip
    gflags-devel glog-devel libibverbs-devel numactl-devel
    boost-devel openssl-devel hiredis-devel
    libcurl-devel jsoncpp-devel libunwind-devel python3-devel
    zstd-devel xxhash-devel pkgconf pkgconf-pkg-config patchelf
    mpich mpich-devel
)

MISSING_CORE=()
for pkg in "${CORE_PACKAGES[@]}"; do
    if ${PKG_MGR} install -y "$pkg" >/dev/null 2>&1; then
        print_ok "已安装: ${pkg}"
    else
        print_warn "安装失败: ${pkg}"
        MISSING_CORE+=("$pkg")
    fi
done

if [ ${#MISSING_CORE[@]} -gt 0 ]; then
    print_warn "以下核心依赖未安装成功（可能需要单独处理）："
    printf '  - %s\n' "${MISSING_CORE[@]}"
fi

# ---------- 5) 安装可选依赖（失败不影响编译主流程）----------
print_section "安装可选依赖（best-effort）"
OPTIONAL_PACKAGES=(
    grpc-devel grpc-plugins protobuf-devel protobuf-compiler
    liburing-devel jemalloc-devel msgpack-devel
)
for pkg in "${OPTIONAL_PACKAGES[@]}"; do
    if ${PKG_MGR} install -y "$pkg" >/dev/null 2>&1; then
        print_ok "已安装: ${pkg}"
    else
        print_warn "跳过（可选）: ${pkg}"
    fi
done

# ---------- 6) 移除可能冲突的 OpenMPI ----------
${PKG_MGR} remove -y openmpi openmpi-devel 2>/dev/null || true

# ---------- 7) 校验 cmake 版本（Mooncake 要求 >= 3.16）----------
print_section "校验 cmake 版本"
if command -v cmake >/dev/null 2>&1; then
    cmake --version | head -1
else
    print_warn "cmake 不在 PATH"
fi

# ---------- 8) 汇总 ----------
print_section "完成"
print_ok "系统依赖安装流程结束。"
if [ ${#MISSING_CORE[@]} -gt 0 ]; then
    print_warn "请重点确认以下包是否可用，必要时用 'sudo dnf search <名字>' 找替代包名："
    printf '  - %s\n' "${MISSING_CORE[@]}"
fi
print_warn "提示：若 cmake 版本 < 3.16，可用 pip/uv 装新版：pip install cmake"
print_warn "提示：记得 source 昇腾 CANN 环境后再编译 Mooncake。"
