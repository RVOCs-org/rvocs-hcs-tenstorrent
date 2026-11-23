# 安装说明

## 两种交付物（每次构建同时产出，安装效果一致）

| 产物 | 用途 | 特点 |
| --- | --- | --- |
| `tt-deps_<ver>_<arch>.deb` | 用 `apt` / `dpkg` 管理（**推荐多机铺开**） | 依赖自动解析、版本可见（`dpkg -l`）、可放内部 APT 仓库统一升级、`purge` 可彻底清理 |
| `tt-deps-<ver>-<arch>.tar.zst` | 解包即用（**推荐单机/离线调试**） | 自带全部内容，可用 `install.sh --skip-*` 精细控制，不依赖 dpkg 数据库 |

两者是**同一份 payload**（tar 包内目录 = `.deb` 的 `/opt/tt-deps`），所以装完的系统状态完全相同：
驱动就位、三个命令可直接执行、1G 大页持久化、udev 规则生效。

---

## 方式 A：`.deb`（apt / dpkg）

### 安装 / 升级

```bash
# 全新安装（apt 会自动装 dkms/build-essential/python3-venv/zstd/systemd 等依赖）
sudo apt install ./rvocs-tt-deps_<version>_<arch>.deb

# 升级：版本号不同时，dpkg 自动执行旧版 prerm → 新版 postinst
sudo apt install ./rvocs-tt-deps_<new-version>_<arch>.deb

# 或先 dpkg 再补依赖
sudo dpkg -i rvocs-tt-deps_<version>_<arch>.deb && sudo apt -f install
```

安装过程中：`postinst` 调用 `/opt/tt-deps/install.sh --yes`；**失败会让 dpkg 报错**（不会静默成功）。
安装/重装默认对 n300 刷 `manifest.yaml` 的 `firmware.n300`（当前 `19.17.1`）；
不想刷用 `sudo TT_DEPS_SKIP_FLASH=1 apt install ...`。

### 重装同版本

`uninstall.sh` 只清系统状态（驱动、工具、大页单元、udev 规则），包仍登记在 dpkg 里；
同版本 `sudo apt install ./x.deb` 会提示 “already the newest version” 并跳过 postinst。三种做法任选：

```bash
# 1) 强制重装（推荐）
sudo apt install --reinstall ./rvocs-tt-deps_<version>_<arch>.deb

# 2) 走编排层（检测到同版本已安装时会自动 --reinstall）
../rvocs-main/rvocs.sh --target tt-host --arch x86 --install

# 3) 先注销包，再普通安装
sudo /opt/tt-deps/uninstall.sh --purge
sudo apt install ./rvocs-tt-deps_<version>_<arch>.deb
```

### 卸载

```bash
# 只卸系统状态，保留 dpkg 注册与 /opt/tt-deps
sudo /opt/tt-deps/uninstall.sh
sudo /opt/tt-deps/uninstall.sh --keep-kmd      # 保留内核驱动

# 彻底卸载：--purge 会 dpkg -r（/opt/tt-deps 随包删除），并清 /etc/tenstorrent
sudo /opt/tt-deps/uninstall.sh --purge
# 或者直接走 apt（prerm 会调用 uninstall.sh）
sudo apt purge tt-deps
```

`uninstall.sh --purge` 在用户直接执行时会附带 `dpkg -r tt-deps`（从 prerm 调用时不会递归）。
卸载后大页的**内核值**仍保留，但不再开机配置。

### 查看与重跑安装步骤

```bash
dpkg -l tt-deps                 # 版本/状态
dpkg -s tt-deps                 # 依赖等元数据
dpkg -L tt-deps | head          # 包内文件（都在 /opt/tt-deps）
dpkg -V tt-deps                 # 文件完整性

# 只补工具 / 只重配大页 / 只跑自检
sudo /opt/tt-deps/install.sh --skip-kmd --skip-hugepages
sudo /opt/tt-deps/install.sh --skip-kmd --skip-tools
sudo /opt/tt-deps/verify.sh
```

**注意**

- `Conflicts: tt-smi, tt-flash, tt-topology`：若系统里有同名 apt 包，安装会被拒绝——请先移除，避免两套工具并存；
- 若 `/usr/bin/tt-smi` 等是手工放置的，本包不会删除它，但 `/usr/local/bin/tt-*` **优先级更高**，实际生效的是本包的版本（`postinst` 会打印提示）；
- 离线环境：`apt install ./x.deb` 在缺依赖时会失败，改用 `dpkg -i` 前先确认 `dkms python3-venv zstd` 已装。

### 放进内部 APT 仓库（可选）

```bash
# 生成仓库索引（GPG 签名可选）
apt-get install -y dpkg-dev apt-utils
cd /srv/apt-repo && cp /path/tt-deps_*.deb ./
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
apt-ftparchive release . > Release     # 需要签名时用 gpg 再生成 InRelease

# 客户端
echo "deb [trusted=yes] http://<repo-host>/apt-repo ./" | sudo tee /etc/apt/sources.list.d/tt.list
sudo apt update && sudo apt install tt-deps
```

---

## 方式 B：`.tar.zst`（离线自包含）

```bash
tar --zstd -xf rvocs-tt-deps_<version>_<arch>.tar.zst
cd rvocs-tt-deps_<version>_<arch>

sudo ./install.sh --check     # 只看前置条件，不改系统
sudo ./install.sh             # 驱动 + 工具 + 大页 + udev
./verify.sh                   # 自检（无卡机器上设备项为 WARN）
sudo ./uninstall.sh           # 卸载（--keep-kmd 保留驱动，--purge 连配置一起删）
```

`uninstall.sh --purge` 只清本目录安装的系统状态；如果之前用 `.deb` 安装，包仍登记在 dpkg，
按「方式 A → 重装同版本 / 卸载」处理。

`install.sh` 可选参数：

| 参数 | 说明 |
| --- | --- |
| `--check` | 只做前置检查（架构/发行版/内核头文件/wheelhouse） |
| `--skip-kmd` / `--skip-tools` / `--skip-hugepages` | 跳过对应部分 |
| `--skip-flash` | 跳过 n300 固件升级（apt 安装时可用 `TT_DEPS_SKIP_FLASH=1` 传给 postinst） |
| `--yes` | 非交互（`.deb` 的 postinst 用的就是它） |

安装末尾会读包内 `manifest.yaml` 的 `firmware.n300`（当前 `19.17.1`），用 `tt-smi -s` 的
`board_info.board_type` 判断板卡；是 n300 时执行 `tt-flash flash -d 19.17.1` 更新固件。
其他板卡、未安装工具或读不到板卡信息时跳过；刷写失败只告警，不会让安装失败。
改固件版本只改 YAML；临时不刷写用 `--skip-flash`。

---

## 安装后的系统状态（两种方式相同）

| 项 | 位置 / 命令 |
| --- | --- |
| 驱动 | `/lib/modules/$(uname -r)/updates/tenstorrent.ko`（或 DKMS 安装），`/etc/modules-load.d/tenstorrent.conf` 开机自动加载 |
| 设备权限 | `/etc/udev/rules.d/99-tenstorrent.rules` → `/dev/tenstorrent/*` 0666 |
| 工具 | `/opt/tenstorrent/tools/<tool>`（每工具独立环境）；`/usr/local/bin/tt-{smi,flash,topology}` 包装脚本，**无需 venv、运行不需要 sudo** |
| 大页 | `/opt/tenstorrent/bin/hugepages-setup.sh`；`dev-hugepages\x2d1G.mount` + `tt-hugepages.service`（开机按 NUMA 自动分配） |
| 记录 | `/etc/tenstorrent/install-manifest.yaml` |

## 支持矩阵

| 架构 | 发行版 | 内核 | 驱动方式 |
| --- | --- | --- | --- |
| riscv64 | Ubuntu 26.04 | `7.0.0-38-generic` | 预编译 `.ko`（命中则免编译）+ DKMS 兜底 |
| x86_64 | Ubuntu 22.04 / 24.04 / 26.04 | 目标机现有内核 | DKMS（需 `linux-headers-$(uname -r)`） |

## 大页配置

| 项 | 说明 |
| --- | --- |
| 算法 | 移植自 `/opt/es/bin/hugepages-setup.sh`：BH 4 页/卡、WH 4 页/卡、GS 1 页/卡，按 NUMA 节点分别写入 |
| 覆盖 | `/etc/tenstorrent/hugepages-override.txt` 写**总页数**（按卡数均分）；兼容旧路径 `/opt/es/bin/hugepages-override.txt` |
| 手动执行 | `sudo /opt/tenstorrent/bin/hugepages-setup.sh --show / --apply / --dry-run` |
| 持久化 | `tt-hugepages.service`（oneshot，开机 `--apply`）+ `dev-hugepages\x2d1G.mount` |

## 常见问题

| 现象 | 处理 |
| --- | --- |
| `apt install ./x.deb` 报依赖 | `sudo apt -f install`；离线时先装 `dkms build-essential python3-venv zstd` |
| 卸载后 `tt-smi` 还能执行 | 检查 `/usr/local/bin`（本包的包装脚本）与 `/opt/tenstorrent`（`uninstall.sh` 会清）；旧版未清干净时手删 |
| `modprobe tenstorrent` 失败 | `dmesg \| grep -i tenstorrent`；无卡机器属正常；`dkms status` 看编译结果 |
| `/dev/tenstorrent` 为空 | `lspci -d 1e52:` 确认设备；驱动未绑定时重插/重启 |
| 工具与系统旧版冲突 | 本包 `Conflicts` 已声明 apt 同名包；手工安装的旧版请手动移除 |
| 大页数量少于期望 | 内存不足或碎片；`cat /proc/meminfo \| grep Huge`，或用 override 指定更小值 |
| 固件升级 | 安装/重装时检测到 n300 会自动执行 `tt-flash flash -d <firmware.n300>`（当前 `19.17.1`）；`--skip-flash` / `TT_DEPS_SKIP_FLASH=1` 可跳过；失败只告警，可手动重试 |
