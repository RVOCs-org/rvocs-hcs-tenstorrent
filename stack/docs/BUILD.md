# 构建指南

## 前置条件

| 项 | 要求 |
| --- | --- |
| 主机 | riscv64（实测 80 核 / 121 GiB 内存 / 可用磁盘 ≥ 200 GiB；构建 Rust 扩展时内存不足可能 OOM） |
| OS | Ubuntu 24.04+；glibc ≥ 2.38（SFPI 内置预构建包的要求） |
| Docker | 24+，含 buildx（支持 `--build-context` 与 `RUN --mount=type=bind,from=`）；用户需在 `docker` 组 |
| root | **不需要**。基础镜像默认 `FROM ubuntu:26.04`（官方 riscv64 镜像）构建，无需 `debootstrap`、无需 sudo |
| 网络 | `--proxy auto` 自动探测；国内网络走 gh-proxy + 清华镜像 |

```bash
sudo apt-get install -y docker.io docker-buildx     # 不再需要 debootstrap
sudo usermod -aG docker "$USER" && newgrp docker
```

## 一键构建（riscv64）

```bash
git checkout RISCV-Porting
./scripts/build.sh --proxy auto
```

等价于依次执行五个阶段，可单独重跑：

```bash
./scripts/build.sh --stage fetch    # 子模块（跳过无关嵌套项）+ wheelhouse/rustup-init（sha256 校验）
./scripts/build.sh --stage workdir  # 生成自包含源码树（本地克隆）+ 应用补丁 + SFPI 预检 + 资产就位
./scripts/build.sh --stage base     # 基础镜像（FROM 官方 ubuntu:26.04，无需 root；幂等跳过）
./scripts/build.sh --stage image    # 主镜像 docker build（分层缓存）
./scripts/build.sh --stage verify   # 组件级验收
```

### 常用选项

| 选项 | 说明 |
| --- | --- |
| `--proxy cn\|direct\|auto` | 网络模式（默认 auto：探测 github.com） |
| `--workdir DIR` | 构建工作区（默认 `<repo>/work`） |
| `--image-tag TAG` | 主镜像 tag（默认见 `scripts/lib/common.sh`） |
| `--sfpi-prebuilt DIR` | 用指定目录下的 `sfpi_*.txz`（优先级高于内置包） |
| `--no-sfpi-prebuilt` | 强制容器内源码编译 SFPI 工具链（约 90 分钟） |
| `--stage NAME` | 只跑指定阶段 |

### SFPI 工具链包的默认行为

riscv64 无官方预编译 SFPI 包。本仓库在 `assets/sfpi-prebuilt/` 内置了一份
**由源码构建（pin 7.78.0）** 的工具链包，`workdir` 阶段默认使用它，从而跳过约 90 分钟的编译：

```
优先级：--no-sfpi-prebuilt  >  --sfpi-prebuilt DIR  >  assets/sfpi-prebuilt/*.txz  >  源码编译
```

使用前会做三项预检（任一失败即**自动回退源码编译**并给出原因）：

1. **文件名匹配**：用 `tt_metal/sfpi-info.sh CMAKE txz` 计算本机期望名（架构 + OS 家族 + 版本 pin），
   与包名逐字比对——这与 tt-metal CMake 的消费逻辑一致（`hw/CMakeLists.txt` 只看文件名存在性）；
2. **sha256**：若同目录有 `*.txz.sha256` 侧车文件则校验；
3. **可执行冒烟**：解包后运行 `riscv-tt-elf-g++ --version`（同时验证主机架构与 host glibc），
   再用 `-mcpu=tt-bh -mabi=ilp32` 编译一个最小目标文件。

> 内置包是在 **Ubuntu 26.04 / glibc 2.38+ / riscv64** 上构建的：目标主机需 riscv64 且 glibc ≥ 2.38
> （Ubuntu 24.04+ / Debian 13+）。不满足时预检会失败并自动走源码编译，无需人工干预。

### 环境变量

`WORK_DIR`、`IMAGE_TAG`、`BASE_IMAGE`、`JOBS`、`PROXY_MODE`、`NO_SFPI_PREBUILT`、`SFPI_PREBUILT_DIR`、
`BASE_OS_IMAGE`、`BASE_IMAGE_REF`、`BASE_PULL`、`USE_DEBOOTSTRAP`、`UBUNTU_CODENAME`、`UBUNTU_MIRROR`
均可用环境变量覆盖（`scripts/lib/common.sh`）。

### 基础镜像：不需要 root

riscv64 没有官方的 tt-metalium 基础镜像，需要自建。构建脚本按下述顺序处理，**默认路径不需要 sudo**：

| 顺序 | 行为 | 触发条件 |
| --- | --- | --- |
| ① | 本地已存在 `BASE_IMAGE` → 跳过 | 默认 |
| ② | `docker pull`（制品分发） | `BASE_PULL=1` 或设置 `BASE_IMAGE_REF` |
| ③ | `FROM ${BASE_OS_IMAGE}` 直接构建（默认 `ubuntu:26.04`，官方 riscv64 镜像） | 默认 |
| ④ | 容器内跑 `debootstrap` 生成 minbase rootfs（保真选项，仍无需宿主 root） | `USE_DEBOOTSTRAP=1` |

```bash
# 默认：零 root
./scripts/build.sh --stage base

# 用内部镜像仓库的 Ubuntu 基础镜像
BASE_OS_IMAGE=registry.local/ubuntu:26.04 ./scripts/build.sh --stage base

# 从 GHCR 拉现成的基础镜像（需先由制品流程推送）
BASE_IMAGE_REF=ghcr.io/<org>/tenstorrent/base-ubuntu-26.04-riscv64:v1 BASE_PULL=1 \
  ./scripts/build.sh --stage base

# 保真：容器内 debootstrap
USE_DEBOOTSTRAP=1 ./scripts/build.sh --stage base
```

失败时脚本会直接打印三种人工兜底：`docker save/load` 导入、手工预建（一次 sudo）、最小权限免密 sudo
（只给 `debootstrap/tar/rm`；`docker` 因用户在 docker 组本就不需要 sudo）。

### 源码树与子模块（两个易踩点，已处理）

- **workdir 生成的是"自包含源码树"**：用 `git clone --local` 而不是 `cp -a` 复制子模块。
  原因是子模块的 `.git` 是指向超级仓 `.git/modules` 的相对路径文件，`cp -a` 到 `work/` 后层级变化会失效，
  导致补丁 `git apply` 报 `not a git repository`、容器内 `uv pip install -e .` 取不到版本。
  克隆保留 tag（`setuptools-scm` / `cmake/version.cmake` 能取到正确版本），并用硬链接复制对象（无路径依赖）。
- **fetch 会跳过无关的嵌套子模块**：`tt-inference-server` 的 `tt-media-server` 下有两个子模块
  （`Mooncake` 用 SSH URL、`tt-llm-engine` 经代理需认证），与镜像构建无关且必然失败，
  已在 `scripts/01-fetch.sh` 的 `IGNORED_SUBMODULES` 与 `manifest.yaml` 的 `submodules.ignored` 中登记，
  通过 `submodule.<name>.update=none` 跳过；其余嵌套子模块（含将来新增的构建相关项）仍会被自动拉取。
  若升级上游后出现新的无关子模块，按报错提示把它加入上述两处清单。

## 开发者流程：只准备源码 / 改完源码再出镜像

支持分阶段执行，**可以只跑 `fetch` + `workdir` 拿到"已打补丁、可编辑"的源码而不构建镜像**：

```bash
./scripts/build.sh --stage prep          # = fetch + workdir（不构建镜像）
#   等价于：
#   ./scripts/build.sh --stage fetch
#   ./scripts/build.sh --stage workdir

# 修改源码（只改 work/，不要动 upstream/）
vim work/tt-inference-server/tt-metal-src/tt_metal/impl/xxx.cpp
vim work/tt-inference-server/vllm-tt-plugin-src/docs/install-vllm-tt.sh

# 出镜像（复用缓存；改动点之后的层会重建）
./scripts/build.sh --stage image
./scripts/build.sh --stage verify
```

### 阶段依赖与可单独执行性

| 阶段 | 前置 | 说明 |
| --- | --- | --- |
| `fetch` | 无 | 子模块 + `work/assets/` 离线资产（wheelhouse / rustup-init） |
| `workdir` | `fetch`（需要 wheelhouse 与 rustup-init） | 复制源码 + 打补丁 + SFPI 预检 + `model_spec.json` |
| `base` | 无（无网也可，除 debootstrap 拉包） | 基础镜像；已存在则跳过 |
| `image` | `workdir` | 缺失时脚本会明确报错提示先跑 `workdir` |
| `verify` | `image` | 镜像组件验收 |

### ⚠️ 重要：`workdir` 会整体重建工作区

`workdir` 执行 `rm -rf work/tt-inference-server work/sfpi-src work/tt-smi-src` 后重新复制，
**`work/` 里的手工改动会丢失**（脚本会在删除前打印警告）。因此：

- 改完源码后**不要**再跑 `workdir`/`prep`，直接 `--stage image`；
- 若改动需要长期保留，请固化成补丁（见第 3 节「新增一个补丁」）：
  ```bash
  git -C work/tt-inference-server/tt-metal-src diff -- <file> \
    > patches/riscv64/tt-metal/1008-my-fix.patch
  echo 1008-my-fix.patch >> patches/riscv64/tt-metal/series
  ```

### 不同改动的重建代价（决定迭代方式）

| 改动位置 | 触发的重建 | 约耗时（80 核，含内置 SFPI 包） |
| --- | --- | --- |
| `work/tt-inference-server/tt-metal-src/**`（C++ 或 Python 文件） | venv 层 → C++ 编译层 → 插件 → 运行时 COPY | 25–40 min + 20 min + 30 min |
| `work/tt-inference-server/vllm-tt-plugin-src/**` | 插件层 → 运行时 | ~20 min + 30 min |
| `work/tt-smi-src/**` | tt-smi 层 → 运行时 | ~7 min + 30 min |
| `docker/*.Dockerfile` | 该行及其后所有层 | 视位置而定 |

> 纯 Python 逻辑调试若不想每次都重编，可把对应 Python 目录挂载进已构建的容器覆盖运行
> （例：`-v $PWD/work/tt-inference-server/tt-metal-src/ttnn/ttnn:/home/container_app_user/tt-metal/ttnn/ttnn`），
> 验证通过后再按上面的流程正式重建。

## 耗时参考（80 核 riscv64 实测）

| 阶段 | 耗时 |
| --- | --- |
| fetch（首次，含 sfpi 子模块 2 GB） | 15–30 min |
| base（基础镜像） | 8–12 min |
| image（**使用内置/指定 SFPI 包**） | 2–2.5 h |
| image（`--no-sfpi-prebuilt` 源码编译工具链） | 3.5–4 h（实测 3h58m） |
| verify | 2 min |

## 缓存与增量重建

- Docker 分层缓存：C++ 编译层（耗时大头）成功后，只改插件/依赖时重跑 `--stage image` 不会重编 tt-metal；
  上游层（venv）变化才会触发 C++ 重编。
- `--stage workdir` 会**重建工作区**（重新复制源码、重放补丁），不影响 Docker 缓存。
- 基础镜像存在即跳过；重建请先 `docker rmi local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1`。

## 生成/提取 SFPI 包

- **从镜像中提取**（源码编译路径跑完后）：

```bash
docker run --rm --entrypoint /bin/bash "$IMAGE_TAG" \
  -c 'cat /home/container_app_user/tt-metal/runtime/sfpi_7.78.0_riscv64_debian.txz' \
  > work/sfpi-prebuilt/sfpi_7.78.0_riscv64_debian.txz
sha256sum work/sfpi-prebuilt/*.txz    # 与 assets/README.md 记录比对
```

- 若要替换仓库内置包：覆盖 `assets/sfpi-prebuilt/` 下的 txz 与 `.sha256`，并在
  `manifest.yaml`、`assets/README.md` 中更新记录。

## x86_64（master 分支）

```bash
./scripts/build.sh --proxy direct   # 官方上游 Dockerfile 路径（实验性便捷入口）
```

## 故障排查

网络封锁、`PyImport_AddModuleRef`、dockerignore 与 bind mount、ThinLTO/mold、
`--no-build-isolation` 缺后端等全部已知问题见 [PORTING.md](PORTING.md) 第 13 节（RISCV-Porting 分支）。

## 升级上游版本

1. 修改子模块指向新 pin：`git -C upstream/tt-metal checkout <new-tag>`；
2. 重放补丁：`./scripts/build.sh --stage workdir`，按报错修复失效补丁（`git apply --check` 定位）；
3. 检查 SFPI 版本 pin 是否变化（`tt_metal/sfpi-info.sh`），必要时重建/替换内置包；
4. 全量构建 + verify；5. 更新 `manifest.yaml` 并提 PR（CI 会自动做补丁应用检查）。
