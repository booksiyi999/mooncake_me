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

### 4. 确认编译产物

```bash
ls build/mooncake-transfer-engine/example/
# 应包含：transfer_engine_ascend_direct_perf  transfer_engine_bench  ...
```

---

## 四、运行（910B 传输测试）

可执行文件在 `build/mooncake-transfer-engine/example/` 下。

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

| 报错 | 原因 | 解决 |
|------|------|------|
| `extern/pybind11 does not contain a CMakeLists.txt` | 子模块没拉 | `git submodule update --init --recursive` |
| `gtest/gtest.h not found` | 单元测试默认开 | cmake 加 `-DBUILD_UNIT_TESTS=OFF` |
| `atomic_flag::test()` / `<semaphore>` 报错 | GCC 10 缺 C++20 标准库 | 确保 `-DWITH_STORE=OFF`（只编 TE） |
| Pod `ErrImagePull/ImagePullBackOff` | 镜像名/策略不对 | 确认 `image: localhost/mooncake-v0310:latest` + `imagePullPolicy: Never` |
| `set_env.sh: No such file or directory` | 挂载符号链接断 | 确认 Pod YAML 挂载整个 `/usr/local/Ascend` |

---

## 六、代码改动后的重新编译

```bash
kubectl exec -it mooncake-build-0310 -- /bin/bash
cd /workspace/mooncake-v0310
git pull   # 若有代码更新（需先切到分支）
cd build
make -j$(nproc)   # 增量编译，很快
```
