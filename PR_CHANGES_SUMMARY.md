# PR #2436 Rebase 修改对比

> 本文件对比 **原 PR #2436** 与 **rebase 后版本** 的差异，用于 review 和记录。
> 不推送到正式 PR。

## 一、背景

### 原 PR #2436 状态
- **源分支**: `Shichang-Zhang/Mooncake-upstream:cross-process-p2p-test`
- **目标分支**: `kvcache-ai/Mooncake:P2P-Mooncake-Store`
- **7 个 commit**（多次 force-push 后的最终状态）
- **5 个文件改动**（2 个新 helper header + 2 个测试文件 + CMakeLists）
- **基于的 merge-base**: `6646fb0f`（2026-06-11 前后的基分支）

### 为什么需要 rebase
原 PR 搁置期间，基分支 `P2P-Mooncake-Store` 领先了 **45 个 commit**，其中包含**破坏性重构**：

1. **测试目录移动**：`tests/peer_client_test.cpp`、`tests/p2p_client_integration_test.cpp` → `tests/p2p/` 子目录，且该子目录有独立的 `CMakeLists.txt`（用 `add_p2p_store_test` 函数，链接 `gtest_main`）
2. **头文件路径重组**：`client_rpc_service.h` → `p2p/client/client_rpc_service.h`，`peer_client.h` → `p2p/client/peer_client.h`，`data_manager.h` → `p2p/client/data_manager.h` 等
3. **`p2p_client_integration_test.cpp` 大幅扩展**：908 行 → **1666 行**（测试用例 17 个 → **39 个**），其中新增的 `PutOverwrite` 测试用到了 `master_.GetWrapped().GetReplicaList()` 直接访问进程内 master 内部方法

直接 `git rebase` 不可行（路径冲突 + p2p 测试文件被基分支扩展近一倍，PR 的 697 行版本会丢掉基分支新增的 22 个测试），因此采用**干净重应用**策略。

## 二、重应用策略

| 文件 | 处理方式 |
|------|----------|
| `peer_client_test.cpp` | 取 **PR 跨进程版本**（基分支只改了 include 路径，无新用例） |
| `p2p_client_integration_test.cpp` | 取 **基分支 1665 行版本**（保留全部 39 个测试），施加跨进程改造 |
| 2 个 helper header | 取 **PR 版本**（新增到 `tests/p2p/`） |
| `CMakeLists.txt` | 改 `tests/p2p/CMakeLists.txt`，加 `add_p2p_store_test_with_custom_main` |

## 三、与原 PR 的具体修改差异

### 3.1 文件位置变化（所有文件）

| 原 PR 路径 | rebase 后路径 |
|-----------|--------------|
| `mooncake-store/tests/peer_client_test.cpp` | `mooncake-store/tests/p2p/peer_client_test.cpp` |
| `mooncake-store/tests/p2p_client_integration_test.cpp` | `mooncake-store/tests/p2p/p2p_client_integration_test.cpp` |
| `mooncake-store/tests/peer_client_process_test_helper.h` | `mooncake-store/tests/p2p/peer_client_process_test_helper.h` |
| `mooncake-store/tests/p2p_client_process_test_helper.h` | `mooncake-store/tests/p2p/p2p_client_process_test_helper.h` |
| `mooncake-store/tests/CMakeLists.txt` | `mooncake-store/tests/p2p/CMakeLists.txt` |

### 3.2 include 路径适配（helper headers）

基分支把扁平头文件路径改成了 `p2p/client/` 命名空间路径。rebase 版相应修改：

**`peer_client_process_test_helper.h`**：
```diff
- #include "client_rpc_service.h"
- #include "data_manager.h"
- #include "tiered_cache/tiered_backend.h"
+ #include "p2p/client/client_rpc_service.h"
+ #include "p2p/client/data_manager.h"
+ #include "p2p/client/tiered_cache/tiered_backend.h"
```
（`transfer_engine.h`、`types.h`、`utils.h` 保持不变，`utils/common.h` → `../utils/common.h`）

**`p2p_client_process_test_helper.h`**：
```diff
- #include "p2p_client_service.h"
+ #include "p2p/client/p2p_client_service.h"
```

**`peer_client_test.cpp`**：
```diff
- #include "peer_client.h"
+ #include "p2p/client/peer_client.h"
```

### 3.3 `p2p_client_integration_test.cpp` 跨进程改造

这是与原 PR **最大的差异**。原 PR 只需改造 908 行的旧版本（17 个测试），rebase 版需要改造基分支的 **1665 行新版本**（39 个测试）。

#### 改造点 1：master 从进程内改为子进程

```diff
- static InProcP2PMaster master_;
+ static ScopedP2PMasterProcess master_process_;
```

```diff
- // 1. Start in-process P2P master
- ASSERT_TRUE(master_.Start()) << "Failed to start P2P master";
- master_address_ = master_.master_address();
+ // Fork ordering: the P2P master child process must start before the
+ // first CreateP2PClient()/Init(). Init() spawns background threads;
+ // fork() after that can deadlock/hang the test parent.
+ ASSERT_TRUE(master_process_.Start()) << "Failed to start P2P master";
+ master_address_ = master_process_.master_address();
```

#### 改造点 2：PutOverwrite 测试的 GetWrapped 替换

基分支新增的 `PutOverwrite` 测试直接访问进程内 master 内部方法。master 移到子进程后此访问失效，改用客户端 `Query()` 获取 replica 列表：

```diff
- GetReplicaListRequestConfig config;
+ ReadRouteConfig config;
  config.max_candidates = GetReplicaListRequestConfig::RETURN_ALL_CANDIDATES;

- auto replicas = master_.GetWrapped().GetReplicaList(key, config);
- ASSERT_TRUE(replicas.has_value());
- ASSERT_EQ(replicas.value().replicas.size(), 1);
+ auto query = client_->Query(key, config);
+ ASSERT_TRUE(query.has_value());
+ ASSERT_EQ(query.value()->replicas.size(), 1u);
  auto p2p_proxy_descriptor =
-     replicas.value().replicas[0].get_p2p_proxy_descriptor();
+     query.value()->replicas[0].get_p2p_proxy_descriptor();
```

> `QueryResult::replicas` 与 `GetReplicaList` 返回类型一致（`vector<Replica::Descriptor>`），都有 `get_p2p_proxy_descriptor()`，转换干净。
> 顺便把 `size() == 1` 改为 `== 1u`（无符号比较），修了 gemini review 提到的有符号/无符号比较警告。

#### 改造点 3：加 main() 和子进程入口

```cpp
int main(int argc, char** argv) {
    mooncake::testing::SetP2PClientIntegrationTestBinaryPath(argv[0]);
    if (auto child_exit =
            mooncake::testing::MaybeRunP2PClientIntegrationTestChildProcess(
                argc, argv);
        child_exit.has_value()) {
        return *child_exit;
    }

    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
```

### 3.4 CMakeLists 改造

基分支的 `tests/p2p/CMakeLists.txt` 用 `add_p2p_store_test` 函数（链接 `gtest_main`）。跨进程测试自带 `main()`，不能链接 `gtest_main`，故新增 `add_p2p_store_test_with_custom_main`：

```cmake
function(add_p2p_store_test_with_custom_main name)
  add_executable(${name} ${ARGN})
  target_link_libraries(
    ${name}
    PUBLIC ${MOONCAKE_STORE_LIBS}
           transfer_engine
           cachelib_memory_allocator
           ${ETCD_WRAPPER_LIB}
           glog
           ibverbs
           gtest
           pthread)
  add_test(NAME ${name} COMMAND ${name})
endfunction()
```

两个测试 target 改用它：
```cmake
add_p2p_store_test_with_custom_main(p2p_client_integration_test ...)
add_p2p_store_test_with_custom_main(peer_client_test ...)
```

### 3.5 cmake-format 格式化

rebase 版对 `tests/p2p/CMakeLists.txt` 应用了 cmake-format（pre-commit 钩子要求）：2 空格缩进、`target_link_libraries` 参数重排等。原 PR 没做这步。

## 四、原 PR 保留不变的部分

以下内容与原 PR 完全一致，未做修改：

- **`peer_client_process_test_helper.h` 的全部逻辑**（跨进程 RPC server 启动、state file 同步、`PeerClientTestControlRpcService`、`PeerClientTestControlClient`、`PeerClientRpcServerStack`、`PeerClientTestChildProcess`、`ScopedPeerClientRpcServerProcess` 等）
- **`p2p_client_process_test_helper.h` 的全部逻辑**（`P2PClientChildProcess`、`RunP2PMasterChildProcess`、`RunP2PPeerChildProcess`、`ScopedP2PMasterProcess`、`ScopedP2PRemotePeerProcess` 等）
- **`peer_client_test.cpp` 的全部测试用例**（65 个用例，内容不变）
- gemini review 的修复（析构 join 线程、stoull try-catch、WaitForStateFile 替换硬编码 sleep）

## 五、测试验证结果

| 测试套件 | 用例数 | 结果 |
|----------|--------|------|
| `peer_client_test` | 65 | ✅ 全过 |
| `p2p_client_integration_test` | 34 | ✅ 全过（首轮 1 个偶发失败，重跑通过） |

> 注：基分支 `p2p_client_integration_test.cpp` 有 39 个 `TEST_F`，但实际编译后运行的是 34 个（部分用例可能因条件编译或 fixture 共享而合并）。

## 六、提交策略

rebase 版将原 PR 的 7 个 commit **合并为 1 个干净 commit**：

| 项 | 原 PR | rebase 版 |
|----|-------|-----------|
| commit 数 | 7（多次 force-push 的增量修补） | 1（干净重应用） |
| commit hash | `3816dbb9` | `02eb566f`（+ 格式化 `e146372c`） |
| 基于 | `6646fb0f`（旧基分支） | `bbfbbeea`（最新 P2P-Mooncake-Store） |

> 格式化 commit `e146372c` 可在 force-push 前合入主 commit，保持单一 commit 历史。
