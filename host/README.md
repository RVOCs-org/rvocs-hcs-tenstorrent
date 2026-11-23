# host/ — Tenstorrent 宿主机依赖

Tenstorrent 宿主机依赖环境的**一键构建 + 单一交付包**：内核驱动（tt-kmd）、工具
（tt-smi / tt-flash / tt-topology）、1G hugepages（NUMA 感知、开机持久化）、udev 规则。

支持 **riscv64** 与 **x86_64**，x86 覆盖 Ubuntu 22.04 / 24.04 / 26.04。

产物命名：`rvocs-tt-deps_<version>_<debarch>.tar.zst` / `.deb`
（如 `rvocs-tt-deps_0.1.0_riscv64.deb`；`VERSION` 的 `v` 前缀会去掉，Debian 版本号需以数字开头）。
`.deb` 通过 `./rvocs.sh --target tt-host --arch <arch> --download` 获取（资产发布在 GitHub Releases）。

> 推理镜像在同仓库的 [`../stack/`](../stack/)，本部分只负责宿主机。

## 仓库约定

- **源码不入库**：`fetch` 阶段从 GitHub 拉官方源码到 `work/src/`（pin 到 manifest 的 ref）；
- **补丁入库**：`patches/{common,<arch>}/<组件>/series`，`patch` 阶段单独应用（与 fetch 解耦）；
- **产物不入库**：`dist/` 只放交付物（`work/`、`dist/` 均已 gitignore）。

## 用户：安装、重装与卸载

推荐用编排层（自动从 Releases 下载最新 `.deb` 并安装）：

```bash
../rvocs-main/rvocs.sh --target tt-host --arch riscv --install
```

或手动安装 `.deb` / `.tar.zst`：

```bash
# .deb：全新安装或升级（版本不同时 dpkg 自动执行 prerm → postinst）
sudo apt install ./rvocs-tt-deps_<version>_<arch>.deb

# .tar.zst：解包后用 install.sh
tar --zstd -xf rvocs-tt-deps_<version>_<arch>.tar.zst
cd rvocs-tt-deps_<version>_<arch>
sudo ./install.sh --check      # 前置检查
sudo ./install.sh              # 驱动(DKMS/预编译) + 工具 + 1G大页 + udev
./verify.sh                    # 自检（无卡机器上设备项为 WARN）
```

重装同版本（`uninstall.sh` 之后，或想重跑 postinst）：

```bash
sudo apt install --reinstall ./rvocs-tt-deps_<version>_<arch>.deb
../rvocs-main/rvocs.sh --target tt-host --arch riscv --install   # 编排层也会强制重装
sudo TT_DEPS_SKIP_FLASH=1 apt install --reinstall ./rvocs-tt-deps_<version>_<arch>.deb   # 不刷固件
```

卸载：

```bash
sudo /opt/tt-deps/uninstall.sh              # 只卸系统状态，保留 dpkg 注册与 /opt/tt-deps
sudo /opt/tt-deps/uninstall.sh --keep-kmd   # 保留内核驱动

sudo /opt/tt-deps/uninstall.sh --purge      # 彻底卸载：/etc/tenstorrent + dpkg -r（/opt/tt-deps 删除）
sudo apt purge tt-deps                      # 或直接走 apt 彻底卸载
```

`uninstall.sh` 不清 `/opt/tt-deps`；`--purge` 之后普通 `apt install ./xxx.deb` 可直接重装，
未 purge 时同版本必须用 `--reinstall`（否则 apt 提示 “already the newest version”）。

安装/重装默认对 n300 刷 `manifest.yaml` 的 `firmware.n300`（当前 `19.17.1`）；
不刷固件用 `install.sh --skip-flash`，`apt install` 时用 `TT_DEPS_SKIP_FLASH=1`。

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
