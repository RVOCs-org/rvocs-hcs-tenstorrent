# 构建说明

## 设计原则

| 项 | 做法 |
| --- | --- |
| **源码** | **不入库**。`fetch` 阶段从 GitHub 拉取到 `work/src/`（浅克隆到 pin 的 ref） |
| **适配补丁** | **入库**。放 `patches/{common,<arch>}/<组件>/series`，`patch` 阶段按序 `git apply` |
| **产物** | **不入库**。输出到 `dist/`（`work/`、`dist/` 均已 gitignore） |

## 六个阶段（可任意单独执行）

| 阶段 | 做什么 | 位置 |
| --- | --- | --- |
| `fetch` | 从 GitHub 拉 5 个官方源码到 `work/src`，pin 到 `manifest.yaml` 的 ref | `work/src/*` |
| `patch` | 重置工作树 → 按 `patches/common/<组件>` 再 `patches/<arch>/<组件>` 顺序 `git apply` | `work/src/*` |
| `wheels` | 每个目标 Python 一套 wheelhouse；有补丁的组件用源码构建，其余优先取 wheel | `work/wheelhouse/py310|py312|py314` |
| `kmd` | （打过补丁的）tt-kmd → DKMS 源码包；`KERNELS` 命中则预编译 `.ko` | `work/kmd/` |
| `bundle` | 组装 `tt-deps-<ver>-<arch>.tar.zst` 与 `tt-deps_<ver>_<arch>.deb`（各附 sha256） | `dist/` |
| `verify` | 结构/脚本语法/各目标 wheel 完整性/`install.sh --check` | `work/verify/` |

## 分步执行（推荐调试时使用）

```bash
./scripts/build.sh --stage fetch      # ① 只拉源码（不碰补丁）
./scripts/build.sh --stage patch      # ② 只打补丁（会先把工作树重置到 HEAD）
./scripts/build.sh --stage wheels     # ③ 生成 wheelhouse
./scripts/build.sh --stage kmd        # ④ 生成 DKMS 包（+预编译 .ko）
./scripts/build.sh --stage bundle     # ⑤ 出包
./scripts/build.sh --stage verify     # ⑥ 自检

./scripts/build.sh --stage patch --revert   # 只回退补丁（回到干净的官方源码）
```

一键全流程（= 上述 6 步）：

```bash
./scripts/build.sh --proxy cn --targets "22.04 24.04 26.04"   # x86_64
./scripts/build.sh --proxy cn                                  # riscv64（默认 26.04）
```

## 新增 / 修改补丁

```bash
./scripts/build.sh --stage fetch            # 先有源码

cd work/src/tt-smi
vim <file>
git diff > ../../../patches/common/tt-smi/0001-my-fix.patch
echo 0001-my-fix.patch >> ../../../patches/common/tt-smi/series

cd - && ./scripts/build.sh --stage patch    # 验证能干净应用
./scripts/build.sh --stage wheels bundle verify
```

- 补丁必须基于 pin 的版本（`manifest.yaml` 的 ref），否则 `git apply` 会失败并提示 rebase；
- 有补丁的组件，`wheels` 阶段一定用源码构建，并用产物**覆盖同版本 PyPI wheel**；
- `tt-kmd` 的补丁会进入 DKMS 包与预编译 `.ko`。

## 环境与后端

| 项 | 说明 |
| --- | --- |
| 构建机 | 与目标同架构；无 root 也可 |
| `WHEELS_BACKEND` | `auto`（默认）/ `docker`（目标发行版容器内构建）/ `uv`（用户级独立 CPython，无需 root） |
| 网络 | `--proxy cn` 走 gh-proxy + 清华 PyPI；`--proxy auto` 自动探测 |

目标 Python：22.04→3.10、24.04→3.12、26.04→3.14（含 riscv64）。
`tt-umd` 的实际版本由工具元数据驱动（`fetch` 会解析并按需切到 `v0.9.12`），无需手工对齐。

## 升级基线

```bash
vim manifest.yaml            # 改 sources.<组件>.ref
./scripts/build.sh --stage fetch patch wheels kmd bundle verify
```

也可以一次执行多个阶段（空格分隔，按顺序）：

```bash
./scripts/build.sh --stage "fetch patch"
./scripts/build.sh --stage "wheels kmd bundle verify"
```

## 交付物

`bundle` 阶段同时产出（不存在 `--deb` 开关，两者都要）：

| 文件 | 安装方式 | 适合 |
| --- | --- | --- |
| `dist/tt-deps-<ver>-<arch>.tar.zst` (+ .sha256) | 解包 + `sudo ./install.sh` | 单机、离线、需要 `--skip-*` 精细控制 |
| `dist/tt-deps_<ver>_<arch>.deb` (+ .sha256) | `sudo apt install ./x.deb` | 多机铺开、内部 APT 仓库、统一升级 |

`.deb` 的关键字段：`Depends: dkms, build-essential, python3, python3-pip, python3-venv, zstd, systemd, udev`、
`Recommends: linux-headers-generic`、`Conflicts: tt-smi, tt-flash, tt-topology`；
维护脚本 `postinst`（失败即报错）/`prerm`（调用 uninstall.sh 真正卸驱动与工具）/`postrm`（purge 清配置）。
细节与两种方式的对照见 [INSTALL.md](INSTALL.md)。

## 调整组件版本 / 跳过补丁

版本优先级：**命令行 / 环境变量 > `manifest.yaml` 的 `sources.*.ref` > 脚本内置默认**。

```bash
# ① 改默认（团队共享）：编辑 manifest.yaml 后重建
vim manifest.yaml
./scripts/build.sh --stage "fetch patch"

# ② 临时指定单个组件（不改仓库）
./scripts/build.sh --tt-smi-ref v6.7.0 --tt-flash-ref v4.0.0
./scripts/build.sh --tt-kmd-ref ttkmd-2.12.0
./scripts/build.sh --tt-umd-ref v0.9.14      # 显式指定后不再按工具元数据自动调整

# ③ 环境变量（CI 里更方便）
TT_FLASH_REF=v4.0.0 ./scripts/build.sh --stage "fetch wheels kmd bundle verify"

# ④ 分支 / commit（非 tag 时自动改为源码构建 wheel）
./scripts/build.sh --tt-smi-ref main
./scripts/build.sh --tt-smi-ref 3f1c2ab

# ⑤ 完全不打补丁构建
./scripts/build.sh --no-patch
./scripts/build.sh --stage "fetch wheels kmd bundle verify" --no-patch
```

| 参数 | 作用 |
| --- | --- |
| `--tt-kmd-ref` / `--tt-umd-ref` / `--tt-smi-ref` / `--tt-flash-ref` / `--tt-topology-ref` | 覆盖单个组件的 ref |
| `--bundle-ver` | 覆盖产物版本号（组件版本变化时建议递增） |
| `--no-patch` | 不应用任何补丁，源码保持官方状态 |

注意事项：

- `tt-umd` 默认按 `tt-smi` / `tt-flash` 的元数据自动对齐（工具要求 `0.9.12` 时不会用 `0.9.14`）；
  显式传 `--tt-umd-ref` 即关闭该行为；
- 目标版本在 PyPI 上不存在（分支、commit、未发布 tag）时，`wheels` 阶段会改为**源码构建**该组件；
- 版本改动后补丁很可能不匹配：先用 `--no-patch` 验证构建链，再决定是否 rebase 补丁；
- 组件版本变化后建议同时 `--bundle-ver` 递增，避免"同版本号、不同内容"的产物。

## RISC-V 移植

### 补丁放置

| 改动性质 | 位置 |
| --- | --- |
| 两个架构通用 | `patches/common/<组件>/series` |
| 仅 riscv64 | `patches/riscv64/<组件>/series` |
| 仅 x86_64 | `patches/x86_64/<组件>/series` |

应用顺序固定为 `common → <arch>`；`--arch` 已决定用哪个架构目录（默认取 `uname -m`）。

### 版本差异用 `ref_by_arch`

riscv 侧工具链对 `tt-umd` 等组件的版本要求可能与 x86 不同，写进 manifest 即可：

```yaml
sources:
  tt-umd:
    ref: v0.9.14
    ref_by_arch:
      riscv64: v0.9.12      # 仅 riscv64 生效
```

优先级：**命令行/env > ref_by_arch.<arch> > ref > 内置默认**。

### 建议的移植流程

```bash
# 0) 先确认官方源码本身能不能构建（不带任何补丁）
./scripts/build.sh --arch riscv64 --no-patch --stage "fetch wheels kmd bundle verify"

# 1) 失败点逐个固化成补丁
cd work/src/<组件> && vim ...
git diff > ../../../patches/riscv64/<组件>/0001-xxx.patch
echo 0001-xxx.patch >> ../../../patches/riscv64/<组件>/series
cd - && ./scripts/build.sh --arch riscv64 --stage patch   # 验证可应用

# 2) 增量验证（每次只重跑受影响的阶段）
./scripts/build.sh --arch riscv64 --stage wheels
./scripts/build.sh --arch riscv64 --stage "kmd bundle verify"
```

### 已知的 riscv64 差异点

| 组件 | 情况 |
| --- | --- |
| `tt-kmd` | 已在 riscv64（Ubuntu 26.04, 7.0.0-31/-38 内核）通过 DKMS 编译，通常无需补丁 |
| `tt-umd` | PyPI 无 riscv64 wheel → 源码构建（nanobind + cmake + g++），可能需要 C++ 侧补丁 |
| `pyluwen` | 无 riscv64 wheel → 需在 **abi3 构建镜像**（`debian:13`）里从 sdist 构建，见下节 |
| `tt-smi` / `tt-flash` / `tt-topology` | 纯 Python，无架构差异 |
| 预编译 `.ko` | 只对 `KERNELS` 里**且本机有头文件**的内核生成，缺失时自动跳过并提示走 DKMS |

`manifest.yaml` 的 `targets.riscv64.kernels` 可列多个内核（例如 `7.0.0-38-generic` 与
`7.0.0-31-generic`），构建机上存在哪个的头文件就预编译哪个。

### 为什么 riscv 需要两个构建镜像

`wheels` 阶段会产出两类 wheel，它们的构建环境要求不同：

| wheel 类型 | 组件 | 构建镜像 | 原因 |
| --- | --- | --- | --- |
| cp314 专用（CPython ABI 绑定） | `tt-umd`、`pydantic-core` 等 | `ubuntu:26.04`（默认目标容器） | 必须用**目标 Python 3.14** 编译，ABI 才对得上 |
| abi3 稳定 ABI（pyo3） | `pyluwen`（0.10.0 与 0.8.5 两个版本） | **`debian:13`**（`wheels.abi3_build_image.riscv64`） | 需要「cargo ≥ 1.85」+「host 三元组标准」两个条件同时成立 |

三元组问题的实测矩阵：

| 镜像 | rustc | host 三元组 | 结果 |
| --- | --- | --- | --- |
| ubuntu:26.04 | 1.93.1 | `riscv64a23-unknown-linux-gnu` | ❌ `target-lexicon` 无法解析 → `Invalid target name` panic |
| ubuntu:24.04 | 1.75.0 | `riscv64gc-unknown-linux-gnu` | ❌ cargo 太旧，maturin 需 edition2024 |
| **debian:13** | **1.85.1** | **`riscv64gc-unknown-linux-gnu`** | ✅ 两个条件同时满足，glibc 2.41 |

```bash
# 默认自动使用 debian:13（仅 riscv64）
./scripts/build.sh --arch riscv64 --stage wheels

# 内部镜像仓库 / 已缓存别名时覆盖（示例：daocloud 镜像源）
ABI3_BUILD_IMAGE=docker.m.daocloud.io/library/debian:trixie \
  ./scripts/build.sh --arch riscv64 --stage wheels

# 强制重建 abi3 wheel（例如升级 pyluwen 后）
ABI3_REBUILD=1 ./scripts/build.sh --arch riscv64 --stage wheels
```

- abi3 wheel 落在 `work/wheelhouse/abi3-riscv64/`，随后以 `--find-links` 注入每个目标 Python 的
  wheelhouse（`wheelhouse_inside.sh` 的 `ABI3_ARGS`），因此 `pip` 不会再去编译 sdist；
- **abi3 与构建时的 Python 小版本无关**：在 3.13 上构建的 `cp311-abi3` wheel 可被 26.04 的 3.14 直接安装；
- 代价是**最低 glibc 被抬到 2.41**（debian:13 的 glibc），所以 riscv 产物只服务 Ubuntu 26.04 及以后，
  不支持 24.04（glibc 2.39）。这一约束记录在 `manifest.yaml: wheels.min_glibc`。

### 什么时候才值得开 RISCV-Porting 分支

| 判据 | 说明 |
| --- | --- |
| 脚本逻辑分叉 > ~15% | 例如 riscv 需要完全不同的驱动安装流程 |
| 产物形态不同 | 例如 riscv 只出 tar、x86 只出 .deb |
| 上游 ref 长期无法统一 | 且 `ref_by_arch` 无法表达 |
| 发布节奏独立 | 需要单独发版/回滚 |

若确实要开分支，分支内只允许改 `patches/riscv64/**` 与 manifest 的 `ref_by_arch`，
并加 CI 检查保证 `scripts/`、`packaging/` 与 `master` 完全一致，避免两份脚本漂移。
