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

```bash
# 安装（apt 会自动装 dkms/build-essential/python3-venv/zstd/systemd 等依赖）
sudo apt install ./tt-deps_0.1.1_amd64.deb

# 或先 dpkg 再补依赖
sudo dpkg -i tt-deps_0.1.1_amd64.deb && sudo apt -f install
```

安装过程中：`postinst` 调用 `/opt/tt-deps/install.sh --yes`；**失败会让 dpkg 报错**（不会静默成功）。

```bash
# 查看
dpkg -l tt-deps                 # 版本/状态
dpkg -s tt-deps                 # 依赖等元数据
dpkg -L tt-deps | head          # 包内文件（都在 /opt/tt-deps）
dpkg -V tt-deps                 # 文件完整性

# 重跑安装步骤（例如只补工具）
sudo /opt/tt-deps/install.sh --skip-kmd --skip-hugepages

# 升级
sudo apt install ./tt-deps_0.1.2_amd64.deb      # dpkg 会自动执行旧版 prerm → 新版 postinst

# 卸载（prerm 会调用 uninstall.sh：卸驱动、删 /usr/local/bin/tt-*、停大页单元、删 udev 规则）
sudo apt remove tt-deps

# 彻底卸载（含 /etc/tenstorrent 配置）
sudo apt purge tt-deps
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
tar -xf tt-deps-0.1.1-x86_64.tar.zst
cd tt-deps-0.1.1-x86_64

sudo ./install.sh --check     # 只看前置条件，不改系统
sudo ./install.sh             # 驱动 + 工具 + 大页 + udev
./verify.sh                   # 自检（无卡机器上设备项为 WARN）
sudo ./uninstall.sh           # 卸载（--keep-kmd 保留驱动，--purge 连配置一起删）
```

`install.sh` 可选参数：

| 参数 | 说明 |
| --- | --- |
| `--check` | 只做前置检查（架构/发行版/内核头文件/wheelhouse） |
| `--skip-kmd` / `--skip-tools` / `--skip-hugepages` | 跳过对应部分 |
| `--yes` | 非交互（`.deb` 的 postinst 用的就是它） |

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
| 想刷固件 | `sudo tt-flash --fw <bundle> <dev>`；**固件需与镜像内 tt-metal 版本匹配**，本包默认不刷 |
