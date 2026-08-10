# Mooncake v0.3.10 部署包（与新版隔离）

本目录存放 **Mooncake v0.3.10** 的部署文件，与新版本（项目根目录）完全隔离。

> 📖 **完整使用手册见 [`USAGE.md`](./USAGE.md)**（镜像构建、编译、运行、排错、重新编译）。

## 为什么用 v0.3.10

新版 Mooncake 需要 GCC 11+（用了 `atomic_flag::test()`、`<semaphore>` 等 C++20 标准库特性），
而 openEuler 22.03 默认 GCC 10 无法编译 mooncake-store。

v0.3.10 的 **Transfer Engine 部分是 GCC 10 兼容的**，只要**只编译 Transfer Engine
（`-DWITH_STORE=OFF`）**就能绕开 mooncake-store 里的 GCC 11 特性。

## 文件

| 文件 | 作用 |
|------|------|
| `mooncake-v0310.Dockerfile` | v0.3.10 编译环境镜像（openEuler + 依赖 + yalantinglibs 0.5.7） |
| `mooncake-build-0310.yaml` | v0.3.10 独立 Pod（与新版 Pod 名字不同，互不影响） |
| `USAGE.md` | **完整使用手册**（构建 / 编译 / 运行 / 排错） |

## 隔离对照

| 项 | 新版 | v0.3.10 |
|----|------|---------|
| 镜像名 | `localhost/mooncake-openeuler:latest` | `localhost/mooncake-v0310:latest` |
| Pod 名 | `mooncake-build-910b` | `mooncake-build-0310` |
| 源码目录（Pod 内） | `/workspace/mooncake_me` | `/workspace/mooncake-v0310` |

## 核心流程速览

```bash
cd ~/mooncake_me && git pull origin main

# ① 构建 v0.3.10 镜像
podman build -t mooncake-v0310:latest -f v0310/mooncake-v0310.Dockerfile .

# ② 导入 K8s + 部署 Pod
podman save localhost/mooncake-v0310:latest -o /tmp/mooncake-v0310.tar
sudo ctr -n k8s.io images import /tmp/mooncake-v0310.tar
rm /tmp/mooncake-v0310.tar
kubectl apply -f v0310/mooncake-build-0310.yaml

# ③ 进 Pod 编译
kubectl exec -it mooncake-build-0310 -- /bin/bash
# ...（详见 USAGE.md 第三节）
```
