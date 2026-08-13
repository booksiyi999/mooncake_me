# Mooncake v0.3.10 — 完整使用手册

本目录是 **Mooncake v0.3.10** 的部署包，面向 **openEuler 22.03 + Ascend 910B** 环境，
兼容 **GCC 10**（只需编译 Transfer Engine）。与新版本（项目根目录）完全隔离。

---

## 一、隔离对照

| 项 | 新版 | v0.3.10 |
|----|------|---------|
| 镜像名 | `localhost/mooncake-openeuler:latest` | `localhost/mooncake-v0310:latest` |
| Pod 名 | `mooncake-build-910b` | `mooncake-build-0310` |
| Pod 内源码目录 | `/workspace/mooncake_me` | `/workspace/mooncake-v0310` |
| 编译产物 | `build/mooncake-transfer-engine/example/` | 同左（v0.3.10 的 build 目录） |

---

## 二、镜像构建

### 1. 拉取部署包（在 Linux 上）

```bash
cd ~/mooncake_me
git pull origin main
```

### 2. 构建镜像

```bash
podman build -t mooncake-v0310:latest -f v0310/mooncake-v0310.Dockerfile .
```

> 出现 `failed to link .../modulefile.4.gz` 是 **无害警告**（man 页链接），不影响编译。

### 3. 导入 K8s 并部署 Pod

```bash
podman save localhost/mooncake-v0310:latest -o /tmp/mooncake-v0310.tar
sudo ctr -n k8s.io images import /tmp/mooncake-v0310.tar
rm /tmp/mooncake-v0310.tar

kubectl apply -f v0310/mooncake-build-0310.yaml
kubectl get pod mooncake-build-0310 -w   # 等 Running
```

> ⚠️ 部署要点（踩坑总结）：
> - **Pod 是临时的**：重建 Pod 后 `/workspace` 里的源码和编译产物会丢失，需要重新 clone + 编译（见第六节）。建议给 `/workspace` 挂 PVC。
> - **Pod YAML 已内置 `privileged: true`**：容器内驱动访问 NPU 设备需要特权，否则运行时报 `get platform info failed, drvErr=4` / `Failed to initialize ACL`。
> - **NPU 设备**通过 hostPath（`/dev/davinci0/1`）挂载，并申请 `huawei.com/Ascend910: "2"`（需集群已装 Ascend device plugin；若未装，可去掉 `resources` 只用 hostPath）。

---

## 三、源码拉取与编译

### 1. 进入 Pod

```bash
kubectl exec -it mooncake-build-0310 -- /bin/bash
```

### 2. 拉 v0.3.10 源码（注意 `--recurse-submodules`，pybind11 子模块必须拉）

```bash
cd /workspace
git clone --depth 1 --branch v0.3.10 --recurse-submodules \
    https://github.com/kvcache-ai/Mooncake.git mooncake-v0310
cd mooncake-v0310

# 如果之前 clone 忘了 --recurse-submodules，补拉子模块：
# git submodule update --init --recursive
```

> `v0.3.10` 是 tag，clone 后处于 detached HEAD 状态，**正常现象**，可直接编译。

### 3. 编译（关键：只编 TE，兼容 GCC 10）

```bash
source /usr/local/Ascend/ascend-toolkit/set_env.sh

mkdir -p build && cd build
cmake .. \
    -DUSE_ASCEND_DIRECT=ON \
    -DUSE_CUDA=OFF \
    -DWITH_STORE=OFF \
    -DWITH_EP=OFF \
    -DWITH_P2P_STORE=OFF \
    -DUSE_HTTP=ON \
    -DBUILD_EXAMPLES=ON \
    -DBUILD_UNIT_TESTS=OFF
make -j$(nproc)
```

**选项说明：**

| 选项 | 值 | 原因 |
|------|-----|------|
| `-DWITH_STORE=OFF` | 必须 | 绕开 v0.3.10 mooncake-store 的 GCC 11 特性（`atomic_flag::test()`） |
| `-DBUILD_UNIT_TESTS=OFF` | 推荐 | 不需要测试，避免装 gtest |
| `-DUSE_ASCEND_DIRECT=ON` | 必须 | 启用 910B 的 Ascend Direct Transport |

> ⚠️ **若用的是修复前构建的旧镜像**：编译前需先把 `/deps/gflags` 重建成共享库，
> 否则运行时报 `flag 'flagfile' was defined more than once ... Aborted (core dumped)`：
> ```bash
> cd /deps/gflags && rm -rf build && mkdir build && cd build && \
>   cmake .. -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
>   make -j$(nproc) && make install
> ```
> 修复后的新镜像（Dockerfile 已加 `-DBUILD_SHARED_LIBS=ON`）不需要这步。

### 4. 确认编译产物

```bash
ls build/mooncake-transfer-engine/example/
# 应包含：transfer_engine_ascend_direct_perf  transfer_engine_bench  ...
```

---

## 四、运行（910B 传输测试）

可执行文件在 `build/mooncake-transfer-engine/example/` 下。

> ⚠️ **每次新开的 shell 都必须先加载运行环境**，否则报
> `libascend_hal.so: cannot open shared object file`：
> ```bash
> source /usr/local/Ascend/ascend-toolkit/set_env.sh
> export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH   # 只加载 /usr/local 这一份 gflags
> # 查看/固定插件分配的可见卡（本机是 5,7，按你环境的实际值调整；不设也行）
> export ASCEND_RT_VISIBLE_DEVICES=5,7
> ```

### 单机双卡测试（P2P 握手模式，无需元数据服务）

**先启动目标端（target）：**

```bash
cd /workspace/mooncake-v0310/build/mooncake-transfer-engine/example

./transfer_engine_ascend_direct_perf \
    --metadata_server=P2PHANDSHAKE \
    --local_server_name=127.0.0.1:12345 \
    --operation=write \
    --device_logicid=0 \
    --mode=target \
    --block_size=16384 \
    --batch_size=32 \
    --block_iteration=10
```

**再启动发起端（initiator）：**

```bash
./transfer_engine_ascend_direct_perf \
    --metadata_server=P2PHANDSHAKE \
    --local_server_name=127.0.0.1:12346 \
    --operation=write \
    --device_logicid=1 \
    --mode=initiator \
    --block_size=16384 \
    --batch_size=32 \
    --block_iteration=10 \
    --segment_id=127.0.0.1:<目标端实际监听端口>
```

> `--segment_id` 填目标端日志里 `listening on <IP>:<端口>` 显示的实际端口（P2P 模式随机选端口）。

### 关键参数

| 参数 | 说明 |
|------|------|
| `--mode` | `target`（服务端）/ `initiator`（客户端） |
| `--metadata_server` | `P2PHANDSHAKE`（单机测试）或 `etcd://ip:2379` / `http://ip:8080` |
| `--device_logicid` | NPU 逻辑设备 ID（0、1、...） |
| `--operation` | `read` / `write` |
| `--segment_id` | 目标端地址，格式 `IP:实际端口` |

---

## 五、常见问题

按“现象 → 原因 → 排查 → 解决”逐一展开。先给一张速查表，后面是每个问题的详细说明。

| # | 报错 | 一句话解决 |
|---|------|-----------|
| 5.1 | `extern/pybind11 does not contain a CMakeLists.txt` | 补拉子模块 |
| 5.2 | `gtest/gtest.h not found` | cmake 加 `-DBUILD_UNIT_TESTS=OFF` |
| 5.3 | `atomic_flag::test()` / `<semaphore>` 编译报错 | 只编 TE（`-DWITH_STORE=OFF`） |
| 5.4 | Pod `ErrImagePull/ImagePullBackOff` | 镜像名 + `imagePullPolicy: Never` |
| 5.5 | `set_env.sh: No such file or directory` | 挂载整个 `/usr/local/Ascend` |
| 5.6 | `libascend_hal.so: cannot open shared object file` | 运行前 `source set_env.sh` |
| 5.7 | `flag 'flagfile' was defined more than once` + `Aborted (core dumped)` | gflags 编成共享库 + 统一 `LD_LIBRARY_PATH` |
| 5.8 | `get platform info failed, drvErr=4` / `Failed to initialize ACL` | Pod 加 `privileged: true` |
| 5.9 | 重建 Pod 后 `cd build` 报 `No such file or directory` | 重编译；或给 `/workspace` 挂 PVC |

---

### 5.1 `extern/pybind11 does not contain a CMakeLists.txt`

- **报错位置**：cmake 配置阶段（`cmake ..` 时）。
- **原因**：clone 源码时没有带 `--recurse-submodules`，`extern/pybind11` 子模块是空的。
- **排查**：`ls extern/pybind11/` 为空，或目录下没有 `CMakeLists.txt`。
- **解决**：
  ```bash
  cd /workspace/mooncake-v0310
  git submodule update --init --recursive
  ```
- **预防**：clone 时务必加 `--recurse-submodules`（见第三节）。

---

### 5.2 `gtest/gtest.h not found`

- **报错位置**：cmake 配置阶段。
- **原因**：项目默认开了单元测试，需要 gtest，但镜像里没装。
- **解决**：编译时加 `-DBUILD_UNIT_TESTS=OFF`（本部署包默认就这么编）。
- **说明**：本部署目标是跑传输测试，不需要单元测试，关掉即可。

---

### 5.3 `atomic_flag::test()` / `<semaphore>` 编译报错

- **报错位置**：`make` 编译 mooncake-store 时。
- **原因**：openEuler 22.03 默认 **GCC 10** 不支持这些 C++20 标准库特性，而 mooncake-store 需要 **GCC 11+**。
- **排查**：`gcc --version` 若显示 `10.x`，即命中此问题。
- **解决**：**只编译 Transfer Engine**，即 cmake 加 `-DWITH_STORE=OFF`（以及 `-DWITH_EP=OFF -DWITH_P2P_STORE=OFF`）。
  ```bash
  cmake .. -DWITH_STORE=OFF -DWITH_EP=OFF -DWITH_P2P_STORE=OFF ...
  ```
- **说明**：v0.3.10 的 Transfer Engine 本身是 GCC 10 兼容的，这是本部署包能用的关键。

---

### 5.4 Pod `ErrImagePull` / `ImagePullBackOff`

- **现象**：`kubectl get pod mooncake-build-0310` 卡在 `ErrImagePull` 或 `ImagePullBackOff`，进不了 Pod。
- **原因**：
  - 集群里没有名为 `localhost/mooncake-v0310:latest` 的镜像（没导入，或镜像名/标签不一致）；
  - 或 `imagePullPolicy` 默认会尝试从远端拉取而失败。
- **排查**：在宿主机 `podman images` 确认镜像名；`kubectl describe pod mooncake-build-0310` 看 Events 里的具体报错。
- **解决**：
  1. 按第二节把镜像导入 K8s：`ctr -n k8s.io images import /tmp/mooncake-v0310.tar`；
  2. 确保 YAML 里 `image: localhost/mooncake-v0310:latest` + `imagePullPolicy: Never`。

---

### 5.5 `set_env.sh: No such file or directory`

- **现象**：在 Pod 里 `source /usr/local/Ascend/ascend-toolkit/set_env.sh` 报文件不存在。
- **原因**：`/usr/local/Ascend/ascend-toolkit/latest` 是指向 CANN 的**符号链接**；Pod 若只挂载了某个子目录而非整个 `/usr/local/Ascend`，符号链接在容器里无法完整解析。
- **排查**：在 Pod 里 `ls -l /usr/local/Ascend/` 看 `ascend-toolkit/latest` 是否指向不存在的目标。
- **解决**：确保 Pod YAML 把**整个** `/usr/local/Ascend` 目录以 `hostPath` 挂载进去（本 YAML 已正确挂载）。

---

### 5.6 `libascend_hal.so: cannot open shared object file`

- **现象**：运行 `transfer_engine_ascend_direct_perf` 时直接报动态库缺失。
- **原因**：当前 shell 没加载 CANN 环境，`LD_LIBRARY_PATH` 里没有 CANN 的 `lib64` 目录，链接器找不到 `libascend_hal.so`（驱动 HAL 库）。
- **排查**：`echo $LD_LIBRARY_PATH` 看是否含 `/usr/local/Ascend` 相关路径；`find /usr/local/Ascend -name libascend_hal.so` 确认库存在。
- **解决**：运行前先加载环境（**每个新开的 shell 都要做一次**）：
  ```bash
  source /usr/local/Ascend/ascend-toolkit/set_env.sh
  ```

---

### 5.7 `flag 'flagfile' was defined more than once` + `Aborted (core dumped)`

- **现象**：程序能启动、打印一堆日志后，报 gflags 冲突并崩溃（`corrupted size vs. prev_size` / `Aborted (core dumped)`）。
- **原因**：进程里同时加载了两套 gflags——
  - 编译期 `/deps/gflags` 源码编译的 gflags（若编成**静态库**，会直接链进二进制）；
  - 运行期系统 RPM 的 gflags（`/usr/lib64/libgflags.so`，由 `glog` 依赖带入）。
  两个 `gflags.cc` 都注册 `flagfile`，gflags 检测到重复直接退出。
- **排查**（在 Pod 里）：
  ```bash
  ldd ./transfer_engine_ascend_direct_perf | grep -i gflags
  ls -l /usr/local/lib/libgflags* /usr/lib64/libgflags* 2>/dev/null
  ```
  若同时出现 `/usr/local/lib` 和 `/usr/lib64` 两份，即命中。
- **解决（推荐，改 Dockerfile）**：gflags 用 `-DBUILD_SHARED_LIBS=ON` 编成共享库（本仓库 Dockerfile 已修复）。
- **解决（不改镜像，旧镜像临时处理）**：
  ```bash
  cd /deps/gflags && rm -rf build && mkdir build && cd build && \
    cmake .. -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install
  cd /workspace/mooncake-v0310/build && cmake .. <同前参数> && make -j$(nproc)
  export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
  ```
  让运行期只用 `/usr/local` 这一份。

---

### 5.8 `get platform info failed, drvErr=4` / `Failed to initialize ACL`

- **现象**：程序能加载驱动库（`DrvGetApiVersion` 成功），但 `drvGetPlatformInfo` / `halGetDeviceInfo` 返回 `ret=4`，最后 `aclInit` 失败并退出。
- **原因**：**容器内驱动访问 NPU 设备被限制**。宿主机上同一套驱动/CANN 是正常的（可用最小 ACL 程序验证），但容器因设备 cgroup / 权限限制无法访问设备。
- **排查**（区分容器 vs 宿主机）：
  ```bash
  # 宿主机上跑最小 ACL 测试：aclInit=0、count=8 说明宿主机正常
  source /usr/local/Ascend/ascend-toolkit/set_env.sh
  gcc /tmp/acl_test.c -o /tmp/acl_test -I/usr/local/Ascend/ascend-toolkit/latest/include \
      -L/usr/local/Ascend/ascend-toolkit/latest/lib64 -lascendcl
  /tmp/acl_test
  # Pod 里看设备 cgroup 放行了哪些设备
  cat /sys/fs/cgroup/devices/devices.list
  ```
- **解决**：Pod 加 `securityContext: { privileged: true }`（本 YAML 已内置），然后删除重建 Pod：
  ```bash
  kubectl delete pod mooncake-build-0310
  kubectl apply -f v0310/mooncake-build-0310.yaml
  ```
- **说明**：privileged 是当前已验证可行的方案；如需收敛权限，可尝试只补必需的设备节点或 capabilities（未验证）。

---

### 5.9 重建 Pod 后 `cd build` 报 `No such file or directory`

- **现象**：`kubectl delete pod` 后再进 Pod，发现 `/workspace/mooncake-v0310/build` 不存在，编译产物没了。
- **原因**：Pod 是**临时**的，`/workspace` 存于容器可写层，Pod 删除即清空。
- **解决**：
  - 临时方案：按第三节重新 clone + 编译；
  - 长期方案：给 `/workspace` 挂一个**持久卷（PVC）**，或把编译产物打进镜像。
- **说明**：本部署包每次重建 Pod 都需重新编译，建议一次跑通后尽快固化（PVC 或镜像）。

---

## 六、代码改动后的重新编译

```bash
kubectl exec -it mooncake-build-0310 -- /bin/bash
cd /workspace/mooncake-v0310
git pull   # 若有代码更新（需先切到分支）
cd build
make -j$(nproc)   # 增量编译，很快
```

> ⚠️ **Pod 重建后 `/workspace` 会清空**（Pod 是临时的），需要按第三节重新
> clone + 编译。若经常重建，建议给 `/workspace` 挂一个持久卷（PVC），
> 或把编译产物打进镜像，避免反复重编译。

---

## 七、版本同步（Windows ↔ 欧拉，走 GitHub）

欧拉机器不方便编辑文件时，可以在 Windows 上改好配置/文档，推到 GitHub 再在欧拉拉取：

**① Windows 上提交并推送：**

```bash
git config --global user.email "你的邮箱"
git config --global user.name "你的名字"

cd d:\hanjiang\mooncake
git add v0310/USAGE.md v0310/mooncake-build-0310.yaml v0310/mooncake-v0310.Dockerfile
git commit -m "v0310: 更新使用文档/修复 gflags 与 privileged 问题"
git push origin feature/v0310
```

**② 欧拉宿主机上拉取并应用：**

```bash
cd ~/mooncake_me
git fetch origin
git checkout -b feature/v0310 origin/feature/v0310   # 首次需建本地分支
git pull origin feature/v0310
kubectl apply -f v0310/mooncake-build-0310.yaml
```

> 若 `git checkout feature/v0310` 报 `pathspec did not match`，先 `git fetch origin`，
> 再用 `git checkout -b feature/v0310 origin/feature/v0310`。
