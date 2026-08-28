# =============================================================================
# mooncake-p2p-test.Dockerfile
# Mooncake P2P Store 测试编译镜像（openEuler + Ascend 910B）
#
# 基于 booksiyi999 验证过的 v0310 Dockerfile 改造，关键区别：
#  - 基础镜像用 openEuler 24.03 LTS（自带 GCC 12.3.1），store 测试需要 C++20 特性
#    (atomic_flag::test() / <semaphore>)，openEuler 22.03 默认 GCC 10 编不了
#    openEuler 没有 gcc-toolset-12 SCL 包，故升基础镜像到 24.03（glibc 2.38 向后兼容）
#  - 装 gtest（v0310 关了测试，本 PR 就是测测试代码）
#  - gflags 编共享库（沿用 v0310 的修复，避免 flagfile 重复注册崩溃）
#  - CANN / NPU 设备运行时从宿主机挂载，不打进镜像
#
# 完全不影响宿主机：所有改动都在容器镜像里
#
# 构建：podman build -t mooncake-p2p-test:latest -f mooncake-p2p-test.Dockerfile .
# =============================================================================

FROM docker.io/openeuler/openeuler:24.03-lts

ENV LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# ---------- 系统依赖（24.03 自带 GCC 12.3.1 + make） ----------
RUN dnf makecache && \
    dnf install -y \
        make \
        cmake ninja-build git wget unzip \
        gcc gcc-c++ \
        gflags-devel glog-devel libibverbs-devel numactl-devel \
        boost-devel openssl-devel hiredis-devel \
        libcurl-devel jsoncpp-devel libunwind-devel \
        gtest gtest-devel \
        python3 python3-pip python3-devel \
        zstd-devel xxhash-devel pkgconf pkgconf-pkg-config patchelf \
        mpich mpich-devel && \
    pip3 install "cmake==3.31.6" && \
    rm -rf /var/cache/dnf

# 验证 GCC 版本（应为 12.3.1）
RUN gcc --version && g++ --version

# ---------- 编译安装 yaml-cpp（openEuler 仓库可能缺 cmake config） ----------
WORKDIR /deps
RUN git clone https://github.com/jbeder/yaml-cpp.git --depth 1 && \
    cd yaml-cpp && mkdir build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install

# ---------- 编译安装 gflags（共享库，沿用 v0310 修复） ----------
# 必须用 -DBUILD_SHARED_LIBS=ON：系统仓库有 gflags-devel（RPM 共享版），
# 若 /usr/local 编成静态库，二进制会同时带"静态+共享"两套 gflags，
# 运行时报: flag 'flagfile' was defined more than once ... Aborted (core dumped)
RUN git clone https://github.com/gflags/gflags.git -b v2.2.2 --depth 1 && \
    cd gflags && mkdir build && cd build && \
    cmake .. -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install

# ---------- 编译安装 yalantinglibs 0.5.7（RPC 依赖） ----------
RUN git clone https://github.com/alibaba/yalantinglibs.git -b v0.5.7 --depth 1 && \
    cd yalantinglibs && mkdir build && cd build && \
    cmake .. -DBUILD_EXAMPLES=OFF -DBUILD_BENCHMARK=OFF -DBUILD_UNIT_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install

WORKDIR /workspace
CMD ["/bin/bash"]
