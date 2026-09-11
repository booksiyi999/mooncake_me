# Mooncake P2P 测试：欧拉服务器容器化编译测试命令速查

> 适用于 openEuler + 昇腾 910B + k8s 环境，测试 PR #2436 的跨进程测试改造。
> 代码仓库：`booksiyi999/mooncake_me`，工作分支：`cross-process-p2p-test-v4`

## 一、什么时候需要重建镜像

| 场景 | 是否重建镜像 |
|------|-------------|
| 只更新了**源代码**（mooncake-store/ 下的 .cpp/.h/CMakeLists） | ❌ 不需要，Pod 挂载宿主机代码 |
| 更新了 **Dockerfile**（p2p-test/mooncake-p2p-test.Dockerfile） | ✅ 需要 |
| 更新了**依赖版本**（yalantinglibs/gflags/gtest 等，在 Dockerfile 里） | ✅ 需要 |
| 第一次搭建环境 | ✅ 需要 |
| 镜像被误删 / `ctr images list` 里找不到 | ✅ 需要 |

> 原理：代码目录通过 hostPath 挂载进容器（宿主机 `/home/hanjiang/pr2436` → 容器 `/workspace/Mooncake`），改代码只影响挂载内容，不影响镜像层。

## 二、无需重建镜像（日常测试，最快路径）

```bash
# ========== 宿主机 ==========

# 1. 更新代码
cd /home/hanjiang/pr2436
git fetch origin
git checkout cross-process-p2p-test-v4
git pull origin cross-process-p2p-test-v4
git submodule update --init --recursive

# 2. 重建 Pod（复用已有镜像）
kubectl delete pod mooncake-p2p-test --ignore-not-found
kubectl apply -f ~/pr2436/p2p-test/mooncake-p2p-test-pod.yaml
kubectl get pod mooncake-p2p-test -w   # 等待 Running，Ctrl+C 退出

# 3. 进入容器
kubectl exec -it mooncake-p2p-test -- /bin/bash
```

```bash
# ========== 容器内 ==========

# 4. 加载环境（每个新 shell 都要执行）
source /usr/local/Ascend/ascend-toolkit/set_env.sh 2>/dev/null || true
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

# 5. 编译（只编译目标测试，约几分钟）
cd /workspace/Mooncake
rm -rf build && mkdir build && cd build
cmake .. \
  -DUSE_ASCEND_CACHE_TIER=OFF \
  -DUSE_ASCEND_DRAM_TIER=OFF \
  -DWITH_STORE=ON \
  -DWITH_P2P_STORE=ON \
  -DUSE_HTTP=ON \
  -DBUILD_UNIT_TESTS=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

cmake --build . --target peer_client_test p2p_client_integration_test -j$(nproc)

# 6. 运行测试
./mooncake-store/tests/p2p/peer_client_test
./mooncake-store/tests/p2p/p2p_client_integration_test

# 增量重编译（只改了源代码时，跳过 cmake 直接 make）
cd /workspace/Mooncake/build
cmake --build . --target peer_client_test p2p_client_integration_test -j$(nproc)
```

## 三、需要重建镜像（首次/改了 Dockerfile）

```bash
# ========== 宿主机 ==========

# 1. 更新代码（同上第 1 步，确保 p2p-test/ 目录存在）
cd /home/hanjiang/pr2436
git fetch origin
git checkout cross-process-p2p-test-v4
git submodule update --init --recursive

# 2. 构建镜像（约 30-60 分钟，含源码编译依赖）
cd p2p-test
podman build -t mooncake-p2p-test:latest -f mooncake-p2p-test.Dockerfile .

# 3. 导入 k8s 容器运行时（containerd）
rm -f /tmp/mooncake-p2p-test.tar
podman save localhost/mooncake-p2p-test:latest -o /tmp/mooncake-p2p-test.tar
sudo ctr -n k8s.io images import /tmp/mooncake-p2p-test.tar
rm -f /tmp/mooncake-p2p-test.tar

# 4. 部署 Pod（YAML 是 sleep infinity 交互模式）
kubectl delete pod mooncake-p2p-test --ignore-not-found
kubectl apply -f mooncake-p2p-test-pod.yaml
kubectl get pod mooncake-p2p-test -w

# 5. 进容器后执行「二」的容器内步骤（4-6）
kubectl exec -it mooncake-p2p-test -- /bin/bash
```

## 四、完整从零开始（代码+镜像全重来）

```bash
# 1. 清理
kubectl delete pod mooncake-p2p-test --ignore-not-found
podman rmi localhost/mooncake-p2p-test:latest 2>/dev/null
sudo ctr -n k8s.io image rm localhost/mooncake-p2p-test:latest 2>/dev/null

# 2. 重新 clone
mkdir -p /home/hanjiang/pr2436
cd /home/hanjiang/pr2436
git clone https://github.com/booksiyi999/mooncake_me.git .
git checkout cross-process-p2p-test-v4
git submodule update --init --recursive

# 3. 按「三」重建镜像并导入

# 4. 按「二」部署 Pod 并在容器内编译测试
```

## 五、常用排障命令

```bash
# Pod 状态 / 为什么卡住
kubectl get pod mooncake-p2p-test
kubectl describe pod mooncake-p2p-test | tail -30

# 容器输出（构建+测试日志）
kubectl logs mooncake-p2p-test
kubectl logs -f mooncake-p2p-test          # 实时跟踪

# 日志里有二进制乱码时，加 -a 强制文本模式
kubectl logs mooncake-p2p-test 2>&1 | grep -a "FAILED"
kubectl logs mooncake-p2p-test 2>&1 | grep -a -E "(PASSED|FAILED|OK)" | tail -20

# 镜像检查
podman images | grep mooncake
sudo ctr -n k8s.io images list | grep mooncake

# podman save 报 "docker-archive doesn't support modifying existing images"
# → 先删旧 tar：rm -f /tmp/mooncake-p2p-test.tar

# exit code 137 = OOM；143 = SIGTERM（资源限制/被杀）
```

## 六、预期结果

```
# peer_client_test
[==========] 65 tests from 1 test suite ran.
[  PASSED  ] 65 tests.

# p2p_client_integration_test（用例数随基分支可能增长）
[==========] 34 tests from 1 test suite ran.
[  PASSED  ] 34 tests.
```

日志中的以下 error 属于**正常现象**（负面测试用例 + 关闭噪声）：
- `ReadRemoteData failed ... OBJECT_NOT_FOUND` / `INTERNAL_ERROR` —— 负面测试预期
- `bind port: 9003 error: Address already in use` —— HTTP server 端口复用，无害
- `server quit with error: operation canceled` —— teardown 正常关闭
- `detected slice leak: allocated N freed 0` —— 已知告警，不影响结果

## 七、本次 v4 版本新增验证点

1. `p2p_client_process_test_helper.h` 编译通过（`InProcP2PMasterConfig` 适配基分支重构）
2. `PutOverwrite` 用例通过（`client_->GetMasterClient().GetReadRoute()` RPC 路径）
3. 基分支新增的用例（若有）不回归
