# 错误日志目录

在 Linux 上遇到编译/运行错误时，将错误输出保存到此目录并推送，即可在 Windows 端拉取分析。

## Linux 端操作

```bash
# 进入项目目录
cd ~/mooncake_me

# 把错误输出保存到文件（示例）
podman build ... 2>&1 | tee error-logs/podman-build-error.log
# 或
cmake .. ... 2>&1 | tee error-logs/cmake-error.log
# 或
make -j$(nproc) 2>&1 | tee error-logs/make-error.log

# 提交并推送
git add error-logs/
git commit -m "error logs"
git push origin main
```

## Windows 端拉取

```bash
git pull origin main
```

所有 `.log` 文件已被 `.gitignore` 排除，这个目录不受影响。
