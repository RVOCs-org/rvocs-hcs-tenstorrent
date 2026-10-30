# 发布流程（Releases）

## 产物清单

| 产物 | 载体 | 大小 | 说明 |
| --- | --- | --- | --- |
| 主 Docker 镜像 | GHCR（`ghcr.io/<org>/tenstorrent/...`） | ~15 GB | GitHub Releases 单文件上限 2 GiB，镜像必须走 GHCR；Release 页只放拉取命令 |
| wheelhouse 打包 | GitHub Releases 附件 | ~170 MB | 5 个 riscv64 cp312 wheel（torch/numpy/pandas/matplotlib/pillow），供离线 fetch |
| SFPI 工具链 txz | **仓库内 `assets/sfpi-prebuilt/`**（同时可作 Release 附件备份） | ~74 MB | `sfpi_7.78.0_riscv64_debian.txz`，默认使用；再分发须附源码获取方式（子模块 pin） |
| rustup-init | 运行时下载（sha256 pin） | ~15 MB | 校验和见 `assets/rustup-init.sha256` |

> 注意：单一文件 > 50 MB 时 GitHub 会在推送时告警，> 100 MB 会被拒绝。当前 txz 为 73.6 MiB，属于"可推送但会告警"。
> 若后续包体变大或仓库体积敏感，可改用 Git LFS，或从仓库移除、仅作为 Release 附件由 `01-fetch.sh` 下载
> （脚本已支持 `--sfpi-prebuilt DIR` 指定本地包）。

## 发布步骤

1. **冻结 pin**：确认 `upstream/*` 子模块指向目标 commit，`manifest.yaml` 同步；
   若 SFPI 版本 pin 变化，重建 `assets/sfpi-prebuilt/` 中的包与 `.sha256`。
2. **构建**：在 riscv64 主机（或自托管 runner）上：
   ```bash
   git checkout RISCV-Porting
   ./scripts/build.sh --proxy auto        # 默认使用内置 SFPI 包
   ./scripts/05-verify.sh                 # 必须 VERIFY_OK
   ```
3. **推送镜像**：
   ```bash
   docker tag "$IMAGE_TAG" "ghcr.io/<org>/tenstorrent/vllm-tt-metal-src-dev-ubuntu-26.04-riscv64:<ver>"
   docker push ghcr.io/<org>/tenstorrent/...
   ```
4. **打 tag 并发布**：tag 格式 `v<tis>_<ttmetal>+<plugin>`（如 `v0.22.0_v0.79.0-rc11+d84049e`），
   上传 wheelhouse 打包、SFPI txz（备份）、rustup-init 附件与校验和。
5. **Release 说明**必含：版本矩阵、镜像拉取命令、SFPI 包 sha256 与 glibc 要求、已知限制、验证状态。

## SFPI 包的三条获取路径（发布时保持一致性）

| 路径 | 用途 |
| --- | --- |
| `assets/sfpi-prebuilt/*.txz` | 默认，源码构建产物入库（`workdir` 阶段预检后使用） |
| Release 附件 + `--sfpi-prebuilt DIR` | 包体不适合入库时的替代方案 |
| `--no-sfpi-prebuilt` | 容器内源码编译（约 90 分钟），用于验证"从零可复现" |

三者必须对应同一个 SFPI 版本 pin（当前 7.78.0），否则文件名预检会拒绝使用。

## 自托管 CI（riscv64）

GitHub Actions 无 riscv64 托管 runner。在那台 riscv64 服务器上可用定时任务替代：

```bash
# crontab 示例：每天 02:00 构建并推送（失败不发版）
0 2 * * * cd ~/rvocs/tenstorrent && git fetch && git checkout RISCV-Porting && \
  ./scripts/build.sh --proxy cn >> work/logs/nightly.log 2>&1 && \
  docker push ghcr.io/<org>/tenstorrent/vllm-tt-metal-src-dev-ubuntu-26.04-riscv64:nightly
```

> amd64 侧的补丁应用检查已由 `.github/workflows/patches-check.yml` 覆盖。

## 版本策略

- 仓库发版 = 5 个上游仓库 pin 的快照 + 对应 SFPI 包；不追上游 main。
- 升级 = 显式 PR（改子模块 pin + 重放补丁 + 必要时重建 SFPI 包 + 全量构建验证），见 BUILD.md「升级上游版本」。
