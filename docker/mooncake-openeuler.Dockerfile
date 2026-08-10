# docker/mooncake-openeuler.Dockerfile
# Mooncake 编译环境镜像 (openEuler + Ascend 910B)
# 用途：提供 Mooncake 编译所需的所有系统依赖，CANN/NPU 设备运行时从宿主机挂载
# 构建：docker build -t mooncake-openeuler:latest -f docker/mooncake-openeuler.Dockerfile .

FROM docker.io/openeuler/openeuler:22.03-lts

ENV LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# ---------- 系统编译依赖 ----------
RUN dnf makecache && \
    dnf groupinstall -y "Development Tools" && \
    dnf install -y --skip-broken \
        cmake ninja-build git wget unzip \
        gflags-devel glog-devel libibverbs-devel numactl-devel \
        boost-devel openssl-devel hiredis-devel \
        libcurl-devel jsoncpp-devel libunwind-devel \
        python3 python3-pip python3-devel \
        zstd-devel xxhash-devel pkgconf pkgconf-pkg-config patchelf \
        mpich mpich-devel \
        grpc-devel grpc-plugins protobuf-devel protobuf-compiler \
        liburing-devel jemalloc-devel msgpack-devel \
        libbsd-devel elfutils-libelf-devel && \
    pip3 install "cmake==3.31.6" && \
    rm -rf /var/cache/dnf

# ---------- 编译安装 yaml-cpp（openEuler 仓库可能缺失 cmake config）----------
WORKDIR /deps
RUN git clone https://github.com/jbeder/yaml-cpp.git --depth 1 && \
    cd yaml-cpp && mkdir build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install

# ---------- 编译安装 gflags（备用，仓库版缺 cmake config 时使用）----------
RUN git clone https://github.com/gflags/gflags.git -b v2.2.2 --depth 1 && \
    cd gflags && mkdir build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install

# ---------- 编译安装 yalantinglibs ----------
RUN git clone https://github.com/alibaba/yalantinglibs.git -b v0.5.7 --depth 1 && \
    cd yalantinglibs && mkdir build && cd build && \
    cmake .. -DBUILD_EXAMPLES=OFF -DBUILD_BENCHMARK=OFF -DBUILD_UNIT_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install

WORKDIR /workspace
CMD ["/bin/bash"]
