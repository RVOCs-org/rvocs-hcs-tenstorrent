# host/ — Tenstorrent 宿主机依赖

Tenstorrent 宿主机依赖环境的**一键构建 + 单一交付包**：内核驱动（tt-kmd）、工具
（tt-smi / tt-flash / tt-topology）、1G hugepages（NUMA 感知、开机持久化）、udev 规则。

支持 **riscv64** 与 **x86_64**，x86 覆盖 Ubuntu 22.04 / 24.04 / 26.04。

产物命名：`rvocs-tt-deps_<version>_<debarch>.tar.zst` / `.deb`
（如 `rvocs-tt-deps_v0.1.0_riscv64.deb`），`<version>` 来自仓库根的 `VERSION`。
`.deb` 通过 `./rvocs.sh --target tt-host --arch <arch> --download` 获取（资产暂托管在 Gitee Releases，迁移到 GitHub Releases 后链接同步切换）。

> 推理镜像在同仓库的 [`../stack/`](../stack/)，本部分只负责宿主机。

## 仓库约定

- **源码不入库**：`fetch` 阶段从 GitHub 拉官方源码到 `work/src/`（pin 到 manifest 的 ref）；
- **补丁入库**：`patches/{common,<arch>}/<组件>/series`，`patch` 阶段单独应用（与 fetch 解耦）；
- **产物不入库**：`dist/` 只放交付物（`work/`、`dist/` 均已 gitignore）。

## 用户：安装

推荐用编排层（自动从 Releases 下载最新 `.deb` 并安装）：

```bash
../rvocs-main/rvocs.sh --target tt-host --arch riscv --install --yes
```

或手动（tar.zst 交付包）：

```bash
tar --zstd -xf rvocs-tt-deps_v0.1.0_riscv64.tar.zst && cd rvocs-tt-deps_v0.1.0_riscv64
sudo ./install.sh --check      # 前置检查
sudo ./install.sh              # 驱动(DKMS/预编译) + 工具 + 1G大页 + udev
./verify.sh                    # 自检（无卡机器上设备项为 WARN）
sudo ./uninstall.sh            # 卸载（--keep-kmd / --purge）
```

`.deb` 也可以直接 `apt-get install ./rvocs-tt-deps_v0.1.0_riscv64.deb`，与 tar 包安装的系统状态一致。

安装后：

- `tt-smi` / `tt-flash` / `tt-topology` **直接可执行**（每工具独立环境 `/opt/tenstorrent/tools/<tool>`，
  `/usr/local/bin` 中是包装脚本；无需激活 venv、运行不需要 sudo）；
- `modprobe tenstorrent` 通过 `/etc/modules-load.d/tenstorrent.conf` 开机自动加载；
- `dev-hugepages\x2d1G.mount` + `tt-hugepages.service` 保证重启后大页仍自动配置。

## 开发者：构建（6 个阶段，可单独/组合执行）

```bash
./scripts/build.sh --stage fetch              # ① 拉源码
./scripts/build.sh --stage patch              # ② 打补丁（--revert 可回退）
./scripts/build.sh --stage "wheels kmd bundle verify"   # ③④⑤⑥

# 一键全流程
./scripts/build.sh --proxy cn --targets "22.04 24.04 26.04"   # x86_64
./scripts/build.sh --proxy cn                                  # riscv64（默认 26.04）
```

| 需求 | 用法 |
| --- | --- |
| 指定组件版本 | `--tt-smi-ref v6.7.0 --tt-flash-ref v4.0.0`（也支持分支/commit） |
| 不打补丁构建 | `--no-patch` |

组件版本 pin 在 `manifest.yaml` 的 `sources:`（tag 或 commit sha），
基线管理用 `scripts/tools/baseline.sh status / apply / check`。

## 结构

```
host/
├── manifest.yaml                # 源码 pin / 目标矩阵 / wheel 策略 / 兼容性（唯一 pin 输入）
├── patches/
│   ├── README.md                # 补丁约定 + 两步执行说明
│   ├── common/{tt-kmd,...}/series      # 两架构通用
│   ├── riscv64/<组件>/series           # 仅 riscv64
│   └── x86_64/<组件>/series            # 仅 x86_64
├── scripts/
│   ├── build.sh                 # 阶段调度（支持 --stage "fetch patch" 组合）
│   ├── 01-fetch.sh … 06-verify-bundle.sh
│   ├── lib/common.sh
│   └── tools/baseline.sh        # 基线管理
├── packaging/                   # install.sh / udev / systemd / hugepages / deb 维护脚本
└── docs/{BUILD,INSTALL}.md
```

## 已知限制

- riscv64 的 tt-kmd 属 beta；固件相关步骤以 Tenstorrent 官方说明为准；
- 预编译 `.ko` 只覆盖 manifest 列出的内核（当前 `7.0.0-38` / `7.0.0-31-generic`），
  其它内核走 DKMS 现场编译（需要内核头文件）；
- tt-umd 版本会被工具元数据（pyluwen）自动微调，日志中 `tt-umd adjusted to ...` 属预期。
