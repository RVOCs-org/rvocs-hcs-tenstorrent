# RISC-V 移植与构建手册（背景资料）

> 本手册完整记录整个移植过程的步骤、命令与踩坑细节。
> **日常构建请直接使用 scripts/build.sh**——手册中的手工步骤已由脚本自动化，
> 但第 13 节（故障排查）与各步骤的设计依据仍然是重要的参考。
> 手册中的 bft-scripts/ 与 ~/bft-build 布局对应本仓库的 scripts/ 与 work/。

# Tenstorrent N300 / vLLM 镜像构建复现手册（riscv64 源码编译）

> 本文档按**实际构建顺序**记录在 RISC-V 服务器上从零构建 `vllm-tt-metal` Docker 镜像的每一步，
> 包含全部命令、补丁内容、失败排查与验收方法。按本手册可人工完整复现。
>
> 构建产物：
> `ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-dev-ubuntu-26.04-riscv64:0.22.0-v0.79.0-rc11-d84049e`（约 15 GB）
>
> 参考部署文档：`Tenstorrent_N300_Qwen部署教程.md`（本文档是它在 **riscv64 平台上的源码构建替代路径**）

---

## 0. 总览

### 0.1 版本矩阵（构建锁定版本）

| 组件 | 版本 / commit | 说明 |
| --- | --- | --- |
| 宿主 OS | Ubuntu 26.04 LTS（codename `resolute`），`riscv64` | 80 核 / 121 GiB 内存 / 913 GiB 磁盘 |
| Docker | 29.1.3（`docker-buildx` BuildKit） | 需支持 `--build-context` 与 `RUN --mount=type=bind,from=` |
| tt-inference-server | **v0.22.0**（`9ef9d660`，2026-09-15） | 部署/工作流框架，提供 Dockerfile 与 app |
| tt-metal（TT-NN / TT-Metalium） | **v0.79.0-rc11**（`29f93c91`） | 从源码编译 |
| vllm-tt-plugin | **main**（`d84049e`） | 内部 pin `vllm==0.30.0` |
| vLLM | **0.30.0**（sdist 源码编译，`VLLM_TARGET_DEVICE=empty`） | riscv64 无官方 wheel |
| SFPI 工具链 | **7.78.0**（`riscv-tt-elf-gcc 15.1.0`） | riscv64 无预编译包，源码构建 |
| tt-smi | **v3.1.1**（含 pyluwen 0.8.5） | 独立 venv |
| Python | **3.12.15**（python-build-standalone，uv 管理） | riscv64 torch/numpy 等 wheel 均为 cp312 |
| torch | **2.14.0+cpu**（RISE 项目 riscv64 wheel） | tt-inference-server 官方 pin 只覆盖 x86_64/aarch64 |
| numpy / pandas / matplotlib / pillow | 2.5.3 / 2.3.3 / 3.11.1 / 12.3.0（cp312 riscv64 wheel） | 来自 RISE 索引 |
| 基础镜像 | `local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1` | 官方无 riscv64 版，自建 |

### 0.2 目录约定

```
~/bft-build/                                  # 全部源码与构建资产（本次要求）
├── base.Dockerfile                           # 基础镜像定义
├── build-manual.sh                           # 主镜像构建入口
├── tt-inference-server/                      # v0.22.0 仓库（构建上下文）
│   ├── tt-metal-src/                         # tt-metal v0.79.0-rc11（含补丁）
│   ├── vllm-tt-plugin-src/                   # 插件 main
│   ├── wheelhouse/                           # riscv64 wheel（torch/numpy/pandas/matplotlib/pillow）
│   ├── vendor/vllm-common.txt                # vLLM 依赖清单（替代被墙的 raw.githubusercontent）
│   ├── model_spec.json                       # 运行时模型规格（仓库自带）
│   └── vllm-tt-metal/vllm.tt-metal.src.dev.riscv64.Dockerfile   # 定制 Dockerfile
├── sfpi-src/                                 # SFPI 7.78.0 源码（含子模块，2.0 GB）
├── tt-smi-src/                               # tt-smi v3.1.1
├── rustup-bin/rustup-init                    # 预下载 rustup 引导程序
└── sfpi-prebuilt/sfpi_7.78.0_riscv64_debian.txz   # 预构建 SFPI 包（可选，省 ~75 分钟）
```

### 0.3 时间与空间预算（80 核实测）

| 阶段 | 耗时 | 备注 |
| --- | --- | --- |
| 源码克隆 + 资源预下载 | 15–30 min | 全程走 gh-proxy / 清华镜像 |
| 基础镜像构建 | 8–12 min | 约 5.5 GB |
| tt-metal Python 环境（venv） | 18–22 min | 含 Rust 包（cryptography/tokenizers/pydantic-core）源码编译 |
| tt-metal C++ 编译 | 25–37 min | **复用预构建 SFPI**；若从头编译 SFPI 再加 ~75 min |
| vLLM + 插件（源码编译） | 35–40 min | grpcio/uvloop/tiktoken/outlines-core/openai-harmony + vLLM Rust 扩展 |
| tt-smi | 6–8 min | pyluwen Rust 编译 |
| runtime 阶段（COPY+chown+apt） | 25–30 min | chown 大树是主要开销 |
| 导出镜像 | 10–15 min | 15 GB |
| **合计** | **≈ 2–2.5 h（复用 SFPI）/ ≈ 3.5–4 h（全新）** | 磁盘峰值占用约 40 GB |

---

## 1. 阶段一：环境勘察

```bash
# 1.1 连接（本地 Windows 用 sshpass 免交互；人工作业可直接 ssh）
ssh ubuntu@10.10.128.101        # 密码 password

# 1.2 记录硬件/系统基线（后续判断资源是否够用）
nproc                            # 80
grep -m1 'model name' /proc/cpuinfo   # riscv64 平台 CPU
free -g                          # 121 GiB
df -h /                          # 913 GiB，可用 ≥ 600 GiB
lsb_release -ds                  # Ubuntu 26.04 LTS
lsb_release -cs                  # resolute
```

**关键前提检查**（缺一不可）：

```bash
# a) 是否已有 Docker（本机预装 29.1.3；若无见 2.4）
docker --version

# b) GitHub 可达性：api.github.com 可达、github.com/raw 直连被阻断 → 必须用 gh-proxy
curl -sI --connect-timeout 10 https://api.github.com | head -1        # 200
curl -sI --connect-timeout 10 https://github.com | head -1            # 可能超时/极慢

# c) PyPI 直连极慢（约 11 KB/s）→ 必须用镜像
curl -s -o /dev/null -w '%{speed_download}\n' --max-time 15 \
  https://pypi.org/simple/numpy/                                       # 约 11 KB/s

# d) GitHub Release 资产直连约 2 KB/s（wheel/rustup/python-build-standalone 都受影响）
#    经 gh-proxy 可达 7 MB/s
curl -s -o /dev/null -w '%{speed_download}\n' --max-time 20 \
  https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download/20250818/cpython-3.12.11+20250818-riscv64-unknown-linux-gnu-install_only_stripped.tar.gz

# e) download.pytorch.org 不可用（索引查询会超时，后文需绕过）
curl -sI --connect-timeout 10 https://download.pytorch.org/whl/cpu/ | head -1

# f) RISE 项目 riscv64 wheel 索引可用（torch/numpy/pandas 等来源）
curl -s --connect-timeout 10 https://pypi.riseproject.dev/simple/torch/ | grep -o 'riscv64' | head -2
```

> 结论：**git 走 gh-proxy、PyPI 走清华、GitHub Release 资产走 gh-proxy、torch 系列从 RISE 预下载**。
> 这四条决定了后续所有步骤的写法。

---

## 2. 阶段二：宿主网络与 Docker 准备

### 2.1 git 全局改写（容器内同样需要，见 9 节 Dockerfile）

```bash
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf https://github.com/
git config --global protocol.file.allow always
git config --global --add safe.directory '*'
cat ~/.gitconfig
```

### 2.2 pip 镜像

```bash
mkdir -p ~/.pip && cat > ~/.pip/pip.conf <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
```

### 2.3 预下载 rustup-init（绕过 sh.rustup.rs 引导脚本抖动）

```bash
# 文件：bft-scripts/fetch-rustup-init.sh
mkdir -p ~/bft-build/rustup-bin && cd ~/bft-build/rustup-bin
for url in \
  "https://static.rust-lang.org/rustup/dist/riscv64gc-unknown-linux-gnu/rustup-init" \
  "https://gh-proxy.com/https://github.com/rust-lang/rustup/releases/download/1.28.2/rustup-init-riscv64gc-unknown-linux-gnu" ; do
  echo "trying $url"
  if curl -sSL --connect-timeout 15 --retry 3 -o rustup-init "$url"; then
    chmod +x rustup-init
    ./rustup-init --version && break
  fi
done
```

Rust 工具链本体后续走清华镜像（`RUSTUP_DIST_SERVER=https://mirrors.tuna.tsinghua.edu.cn/rustup`，已验证提供 `riscv64gc-unknown-linux-gnu` 产物）。

### 2.4 Docker 安装（若宿主未装）

```bash
echo password | sudo -S apt-get update
echo password | sudo -S apt-get install -y docker.io docker-buildx debootstrap
echo password | sudo -S usermod -aG docker ubuntu   # 重新登录生效
docker run --rm hello-world
docker buildx version                                # 必须存在，后续用命名上下文构建
```

---

## 3. 阶段三：源码获取

```bash
cd ~/bft-build

# 3.1 部署框架（构建上下文根）
git clone https://github.com/tenstorrent/tt-inference-server.git
cd tt-inference-server
git checkout v0.22.0                      # 9ef9d660

# 3.2 tt-metal（构建上下文内的子目录，供 Dockerfile 命名上下文注入）
git clone https://github.com/tenstorrent/tt-metal.git tt-metal-src
cd tt-metal-src
git checkout v0.79.0-rc11                 # 29f93c91
git submodule update --init --recursive --depth 1
cd ..

# 3.3 vLLM 插件（内部 pin vllm==0.30.0）
git clone https://github.com/tenstorrent/vllm-tt-plugin.git vllm-tt-plugin-src
git -C vllm-tt-plugin-src checkout d84049e

# 3.4 SFPI 交叉工具链源码（放仓库外，2.0 GB，必须含子模块）
cd ~/bft-build
git clone https://github.com/tenstorrent/sfpi.git sfpi-src
cd sfpi-src
git fetch --depth 1 origin "refs/tags/7.78.0:refs/tags/7.78.0"
git checkout -f 7.78.0
git submodule update --init --recursive --depth 1     # binutils / gcc / newlib

# 3.5 tt-smi（独立 venv 构建）
cd ~/bft-build
git clone https://github.com/tenstorrent/tt-smi.git tt-smi-src
git -C tt-smi-src checkout v3.1.1
```

**校验点**

```bash
git -C ~/bft-build/tt-inference-server describe --tags        # v0.22.0
git -C ~/bft-build/tt-inference-server/tt-metal-src describe --tags   # v0.79.0-rc11
git -C ~/bft-build/vllm-tt-plugin-src rev-parse --short HEAD   # d84049e
git -C ~/bft-build/sfpi-src describe --tags                    # 7.78.0
git -C ~/bft-build/tt-smi-src describe --tags                  # v3.1.1
du -sh ~/bft-build/sfpi-src                                    # ≈2.0G（确认子模块已拉取）
```

---

## 4. 阶段四：离线资源预下载

### 4.1 riscv64 wheelhouse（RISE 项目索引 → 经 gh-proxy 下载）

```bash
# 文件：bft-scripts/fetch-rise-wheels.sh / fetch-rise-wheels2.sh
WH=~/bft-build/tt-inference-server/wheelhouse
mkdir -p $WH && cd $WH
dl() {
  local name=$1 pat=$2
  curl -s --connect-timeout 15 "https://pypi.riseproject.dev/simple/$name/" -o /tmp/rise-$name.html
  local href=$(grep -oE 'href="[^"]*'"$pat" /tmp/rise-$name.html | tail -1 | sed 's/href="//')
  [ -z "$href" ] && { echo "$name: NOT FOUND"; return 1; }
  local clean="${href%%#*}" fname=$(basename "${href%%#*}")
  fname=${fname//%2B/+}
  curl -sL --connect-timeout 15 -o "$fname" "https://gh-proxy.com/$clean"
  ls -lh "$fname"
}
dl torch      'torch-2\.14\.0%2Bcpu-cp312-cp312-manylinux.*riscv64\.whl'
dl numpy      'numpy-2\.5\.3-cp312-cp312-manylinux.*riscv64\.whl'
dl pandas     'pandas-2\.3\.3-cp312-cp312-manylinux.*riscv64\.whl'
dl matplotlib 'matplotlib-3\.11\.1-cp312-cp312-manylinux.*riscv64\.whl'
dl pillow     'pillow-12\.3\.0-cp312-cp312-manylinux.*riscv64\.whl'
```

期望结果（`ls -la $WH`）：

```
torch-2.14.0+cpu-cp312-cp312-manylinux_2_39_riscv64.whl          133 MB
numpy-2.5.3-cp312-cp312-manylinux_2_38_riscv64...whl              12 MB
pandas-2.3.3-cp312-cp312-manylinux_2_34_riscv64...whl             12 MB
matplotlib-3.11.1-cp312-cp312-manylinux_2_39_riscv64.whl          9.8 MB
pillow-12.3.0-cp312-cp312-manylinux_2_38_riscv64...whl            5.8 MB
```

### 4.2 vLLM 依赖清单（vendor）

`install-vllm-tt.sh` 默认从 `raw.githubusercontent.com` 拉取 vLLM 的 `requirements/common.txt`（被墙）。
预先下载到 `vendor/`，构建时 bind mount 到 `/mnt/vendor`：

```bash
# 文件：bft-scripts/prep-context.sh
cd ~/bft-build/tt-inference-server
mkdir -p vendor
curl -fsSL --connect-timeout 15 --retry 3 \
  https://gh-proxy.com/https://raw.githubusercontent.com/vllm-project/vllm/v0.30.0/requirements/common.txt \
  -o vendor/vllm-common.txt
wc -l vendor/vllm-common.txt     # 约 60 行
```

### 4.3 CPM.cmake（tt-metal CMake 依赖管理器的引导文件）

tt-metal 的 `cmake/CPM.cmake` 会 `file(DOWNLOAD)` 从 GitHub Releases 取 `CPM_0.40.2.cmake`（HTTP 下载不受 git insteadOf 改写影响 → 必超时）。
预置到 `.cpmcache/cpm/` 并给引导脚本加“已存在且哈希匹配则跳过”的判断：

```bash
# 文件：bft-scripts/patch-cpm.sh（完整内容见 6.4）
EXPECT=c8cdc32c03816538ce22781ed72964dc864b2a34a310d3b7104812a5ca2d835d
mkdir -p ~/bft-build/tt-inference-server/tt-metal-src/.cpmcache/cpm
curl -sSL --connect-timeout 20 --retry 3 \
  -o ~/bft-build/tt-inference-server/tt-metal-src/.cpmcache/cpm/CPM_0.40.2.cmake \
  "https://gh-proxy.com/https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.40.2/CPM.cmake"
sha256sum ~/bft-build/tt-inference-server/tt-metal-src/.cpmcache/cpm/CPM_0.40.2.cmake   # 必须等于 $EXPECT
```

### 4.4（可选）SFPI 预构建包

SFPI 交叉工具链在 CMake configure 内源码构建需 ~75 分钟。若此前已构建过一次，可从旧镜像/旧构建产物中取回 77 MB 的
`sfpi_7.78.0_riscv64_debian.txz` 放到 `~/bft-build/sfpi-prebuilt/`，构建时会被直接解包（跳过重编）：

```bash
# 文件：bft-scripts/extract-sfpi-prebuilt.sh
mkdir -p ~/bft-build/sfpi-prebuilt
docker run --rm --entrypoint /bin/bash <已构建过的镜像> \
  -c 'cat /home/container_app_user/tt-metal/runtime/sfpi_7.78.0_riscv64_debian.txz' \
  > ~/bft-build/sfpi-prebuilt/sfpi_7.78.0_riscv64_debian.txz
tar -tJf ~/bft-build/sfpi-prebuilt/sfpi_7.78.0_riscv64_debian.txz | head -3   # sfpi/include/sfpi.h
```

> 若省略本步，构建会自动走源码编译路径（见 6.3），只是多花约 75 分钟。

---

## 5. 阶段五：自建 riscv64 基础镜像

官方 `ghcr.io/tenstorrent/tt-metal/tt-metalium/ubuntu-22.04-amd64` 只有 x86，且本机无法访问 Docker Hub，
因此用 **debootstrap 从 Ubuntu ports 构建 riscv64 根文件系统**，再 `docker import` 成基础镜像。

### 5.1 生成基础 rootfs

```bash
echo password | sudo -S rm -rf /var/tmp/rootfs-riscv64
echo password | sudo -S debootstrap --arch=riscv64 --variant=minbase \
  resolute /var/tmp/rootfs-riscv64 http://ports.ubuntu.com/ubuntu-ports
# 结果：/etc/apt/sources.list 为 "deb http://ports.ubuntu.com/ubuntu-ports resolute main"

echo password | sudo -S tar -C /var/tmp/rootfs-riscv64 -c . | docker import - local/ubuntu:26.04-riscv64
docker run --rm --entrypoint /bin/bash local/ubuntu:26.04-riscv64 -c 'head -3 /etc/os-release'
# PRETTY_NAME="Ubuntu 26.04 LTS" / VERSION_ID="26.04"
```

### 5.2 基础镜像 Dockerfile

文件：`~/bft-build/base.Dockerfile`（内容如下，包列表来自 tt-metal `install_dependencies.sh` + `ci-build-light` + SFPI 源码构建前置）

```dockerfile
# riscv64 TT-Metalium 基础镜像（Ubuntu 26.04 + 编译工具链 + uv/python）
FROM local/ubuntu:26.04-riscv64

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Los_Angeles

# debootstrap 只配置了 main 组件，补全 restricted/universe/multiverse
RUN echo "deb http://ports.ubuntu.com/ubuntu-ports resolute main restricted universe multiverse" > /etc/apt/sources.list

# 编译工具链与依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    clang-20 lld-20 llvm-20 libclang-20-dev libclang-rt-20-dev clang-tidy-20 \
    libc++-20-dev libc++abi-20-dev \
    mold cmake ninja-build ccache \
    libboost-all-dev libhwloc-dev libnuma-dev libtbb-dev libcapstone-dev libfmt-dev \
    protobuf-compiler libprotobuf-dev pkg-config \
    zlib1g-dev libssl-dev libffi-dev libisl-dev libexpat1-dev \
    libgmp-dev libmpc-dev libmpfr-dev \
    libsndfile1 libgl1 \
    libsdl3-dev libx11-dev ocl-icd-opencl-dev liblua5.4-dev \
    openmpi-bin libopenmpi-dev \
    git wget curl ca-certificates xz-utils patchelf gosu file jq unzip sudo pandoc xxd \
    python3 python3-dev python3-venv python3-pip python3-pkg-resources \
    autoconf automake bison expect flex gawk patchutils texinfo \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# clang 无版本后缀名
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-20 100 \
    && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-20 100 \
    && clang --version | head -1

# uv + 预置 uv-managed Python 3.12（riscv64 的 torch wheel 仅有 cp312+）
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    PIP_EXTRA_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python
ENV UV_PYTHON_INSTALL_MIRROR=https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download
ENV UV_HTTP_RETRIES=10
RUN pip3 install --break-system-packages --no-cache-dir uv \
    && uv python install 3.12 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python3.12 \
    && /usr/local/bin/python3.12 --version \
    && uv --version

ENV PATH="/usr/local/bin:$PATH"
CMD ["/bin/bash"]
```

### 5.3 构建与验收

```bash
# 文件：/tmp/build-base.sh
cd ~/bft-build
DOCKER_BUILDKIT=1 docker build --network host \
  -t local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1 -f base.Dockerfile .
```

验收（全部必须通过）：

```bash
docker run --rm local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1 bash -c '
clang --version | head -1          # Ubuntu clang version 20.1.8
cmake --version | head -1          # cmake version 4.2.3
ninja --version                    # 1.13.2
grep BOOST_LIB_VERSION /usr/include/boost/version.hpp    # "1_90"
ls /usr/include/hwloc.h && protoc --version
python3.12 --version && uv --version
which autoconf automake bison flex gawk expect makeinfo
gcc --version | head -1            # 15.2.0
'
```

> 说明：`sfpi` 构建脚本还需要 `autoconf/automake/bison/expect/flex/gawk/texinfo(makeinfo)`，已在包列表中。
> 若缺少 `texinfo` 会报 "Common names: ... texinfo" 并在 SFPI 构建阶段失败。

---

## 6. 阶段六：tt-metal 源码 riscv64 适配

所有补丁作用于 `~/bft-build/tt-inference-server/tt-metal-src`，**按以下顺序执行**。

### 6.1 工具链文件（新建）

`cmake/aarch64-linux-clang-20-libstdcpp-toolchain.cmake` 复制改造：

```bash
cd ~/bft-build/tt-inference-server/tt-metal-src
cp cmake/aarch64-linux-clang-20-libstdcpp-toolchain.cmake \
   cmake/riscv64-linux-clang-20-libstdcpp-toolchain.cmake
```

最终内容（**注意 `CMAKE_LINKER_TYPE LLD`**，见 6.5）：

```cmake
set(CMAKE_SYSTEM_PROCESSOR "riscv64")

set(CMAKE_C_COMPILER clang-20 CACHE INTERNAL "C compiler")

set(CMAKE_CXX_COMPILER clang++-20 CACHE INTERNAL "C++ compiler")

# Use for configure time
set(ENABLE_LIBCXX FALSE CACHE INTERNAL "Using clang's libc++")

# riscv64: prefer LLD. mold cannot link ThinLTO objects without LLVMgold.so
# (llvm-20-linker-tools), which is not installed; lld handles ThinLTO natively.
set(CMAKE_LINKER_TYPE LLD)
```

### 6.2 build_metal.sh 默认工具链切换

```bash
sed -i 's|toolchain_path="cmake/x86_64-linux-clang-20-libstdcpp-toolchain.cmake"|toolchain_path="cmake/riscv64-linux-clang-20-libstdcpp-toolchain.cmake"|' build_metal.sh
grep -n 'toolchain_path=' build_metal.sh
```

### 6.3 SFPI 工具链适配（sfpi-info.sh）

riscv64 没有官方预编译 SFPI 包，`sfpi-info.sh` 会走 `BUILD` 分支从源码编译（binutils+gcc+newlib）。
本网络下容器内 `git clone` GitHub 不可用，因此改成“优先使用预置源码 `/mnt/sfpi-src`”，并跳过需要 qemu 的 gcc 测试套件：

```bash
# 文件：bft-scripts/patch-ttmetal-riscv64.sh 的第 2 步（关键片段）
python3 - <<'PYEOF'
p = 'tt_metal/sfpi-info.sh'
s = open(p).read()

old_clone = '''    echo "Cloning the repository ..." | dupstderr
    (set -x
     git clone --depth 1 $sfpi_repo .)
fi
... git submodule update --depth 1 --init --recursive)'''

new_clone = '''# riscv64 adaptation: use pre-staged source when present (bind mount or copy)
if ! [[ -d .git ]]; then
    if [[ -d /mnt/sfpi-src/.git ]]; then
        echo "Using pre-staged sfpi source from /mnt/sfpi-src" | dupstderr
        cp -a /mnt/sfpi-src/. .
    else
        echo "Cloning the repository ..." | dupstderr
        (set -x
         git clone --depth 1 $sfpi_repo .)
    fi
fi
echo | dupstderr
echo "Fetching sfpi $sfpi_version ..." | dupstderr
(set -x
 git fetch --depth 1 origin "refs/tags/$sfpi_version:refs/tags/$sfpi_version" || echo "WARN: tag fetch failed, using staged refs"
 git fetch --depth 1 origin $sfpi_version || echo "WARN: fetch failed, using staged refs"
 git -c "advice.detachedHead=false" checkout -f $sfpi_version || echo "WARN: checkout failed"
 git submodule update --depth 1 --init --recursive || echo "WARN: submodule update failed (using staged submodules)")'''
assert old_clone in s
s = s.replace(old_clone, new_clone)

# 跳过 dejagnu 测试（需要 qemu-riscv32 模拟器跑全套 gcc 测试）
old_build = 'scripts/build.sh --test-tt 2>&1'
new_build = 'scripts/build.sh 2>&1'
assert old_build in s
s = s.replace(old_build, new_build)
open(p, 'w').write(s)
print("sfpi-info.sh patched")
PYEOF
```

### 6.4 CPM 引导补丁（文件：`bft-scripts/patch-cpm.sh`）

```bash
set -e
TT_METAL_SRC=~/bft-build/tt-inference-server/tt-metal-src
EXPECT=c8cdc32c03816538ce22781ed72964dc864b2a34a310d3b7104812a5ca2d835d
DST=$TT_METAL_SRC/.cpmcache/cpm/CPM_0.40.2.cmake
mkdir -p "$(dirname "$DST")"
[ -f "$DST" ] || curl -sSL --connect-timeout 20 --retry 3 -o "$DST" \
  "https://gh-proxy.com/https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.40.2/CPM.cmake"
[ "$(sha256sum "$DST" | awk '{print $1}')" = "$EXPECT" ] || { echo "FATAL: CPM hash mismatch"; exit 1; }

# 让引导脚本在文件已存在且哈希匹配时跳过下载
python3 - "$TT_METAL_SRC/cmake/CPM.cmake" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = """file(
    DOWNLOAD
        https://github.com/cpm-cmake/CPM.cmake/releases/download/v${CPM_DOWNLOAD_VERSION}/CPM.cmake
        ${CPM_DOWNLOAD_LOCATION}
    EXPECTED_HASH SHA256=${CPM_HASH_SUM}
)"""
new = """# riscv64: skip download when a pre-staged, hash-verified copy is present
if(EXISTS ${CPM_DOWNLOAD_LOCATION})
    file(SHA256 ${CPM_DOWNLOAD_LOCATION} _cpm_staged_hash)
endif()
if(NOT _cpm_staged_hash STREQUAL ${CPM_HASH_SUM})
    file(
        DOWNLOAD
            https://github.com/cpm-cmake/CPM.cmake/releases/download/v${CPM_DOWNLOAD_VERSION}/CPM.cmake
            ${CPM_DOWNLOAD_LOCATION}
        EXPECTED_HASH SHA256=${CPM_HASH_SUM}
    )
endif()"""
assert old in s
open(p, 'w').write(s.replace(old, new))
PYEOF
```

> 同时 Dockerfile 里设置了 `CPM_USE_LOCAL_PACKAGES=ON`，让 CPM 优先复用系统 Boost 1.90，避免下载 Boost 源码。

### 6.5 链接器改为 LLD（文件：`bft-scripts/patch-linker.sh`）

现象：`_ttnn.so` 用 `-flto=thin` 链接，选 mold 时报 `LLVMgold.so` 缺失（`ld.mold` 无法处理 ThinLTO 且基础镜像未装 `llvm-20-linker-tools`）。
处置：工具链里 `set(CMAKE_LINKER_TYPE LLD)`（riscv64 的 `cmake/linking.cmake` 会走 mold→LLD 的降级链，但显式指定更稳）。

```bash
cd /tmp && rm -rf ltolinktest && mkdir ltolinktest && cd ltolinktest
echo 'extern "C" int f(){ return 42; }' > a.cpp
clang++-20 -fPIC -O3 -flto=thin -shared -fuse-ld=lld-20 -o a.so a.cpp && echo LLD_THINLTO_LINK_OK
```

### 6.6 streaming profiler 的 AVX2 → simde（文件：`bft-scripts/patch-simde-sprof.sh`）

`tt_metal/impl/streaming_profiler/spsc_marker_decode.hpp` 是 AVX2 专用实现且无标量回退，riscv64 无法编译。
改用 simde 的 AVX2 模拟（与仓库里 `impl/data_format/bfloat8.cpp` 的既有做法一致；x86 上 simde 直接映射原生 intrinsic）：

```bash
python3 - "$TT_METAL_SRC/tt_metal/impl/streaming_profiler/spsc_marker_decode.hpp" <<'PYEOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("#include <immintrin.h>",
  "#if defined(__x86_64__) || defined(__i386__)\n#include <immintrin.h>\n#else\n"
  "// riscv64: no x86 SIMD; simde emulates the AVX2 used below.\n"
  "#include <simde/x86/avx2.h>\n#endif", 1)
s = s.replace('#if !defined(__AVX2__)',
              '#if (defined(__x86_64__) || defined(__i386__)) && !defined(__AVX2__)', 1)
s = re.sub(r'\b_mm(\d*)_', r'simde_mm\1_', s)
s = re.sub(r'\b__m(256i|128i|256d|128d)\b', r'simde__m\1', s)
open(p, 'w').write(s)
PYEOF
grep -n 'simde/x86' $TT_METAL_SRC/tt_metal/impl/streaming_profiler/spsc_marker_decode.hpp
```

> 注意：`_mm256_maskload_epi64` 的掩码参数在 simde 下要求 `const int64_t*`，若编译报该错误，把
> `reinterpret_cast<const long long*>` 改为 `reinterpret_cast<const int64_t*>`。
> 若不想改该文件，也可给 `build_metal.sh` 加 `--disable-profiler`（本次两者都做了，`--disable-profiler`
> 主要为了跳过 Tracy/WASM viewer 依赖下载）。

### 6.7 numpy / matplotlib 版本固定（文件：`bft-scripts/patch-numpy-pin.sh` + `patch-prune8.sh`）

riscv64 没有 `numpy<2` 的 wheel（tt-metal 原本 pin `numpy>=1.24.4,<2`），且未 pin 时 uv 会选清华源的 sdist 重新编译。
处理：放宽 pin 到 2.x，并**固定到 wheelhouse 中的版本**，强制走 wheel：

```bash
F=$TT_METAL_SRC/tt_metal/python_env/requirements-dev.txt
sed -i 's/^numpy>=1\.24\.4,<2$/numpy>=1.24.4/' "$F"     # patch-numpy-pin.sh
sed -i 's/"numpy>=1\.24\.4,<2",/"numpy>=1.24.4",/' $TT_METAL_SRC/pyproject.toml
sed -i 's|^numpy>=1\.24\.4|numpy==2.5.3|' "$F"           # patch-prune8.sh：锁定 wheelhouse 版本
sed -i 's|^matplotlib$|matplotlib==3.11.1|' "$F"
sed -i 's|"numpy>=1\.24\.4"|"numpy==2.5.3"|' $TT_METAL_SRC/create_venv.sh
grep -nE '^(numpy|matplotlib)==' "$F"
```

### 6.8 Python 依赖剪枝（riscv64 无 wheel / 无源码构建条件的包）

tt-metal 的 `requirements-dev.txt` 面向 x86 开发环境，含大量评测/demo 依赖；riscv64 上必须剪除。
**按以下顺序执行**（脚本文件：`bft-scripts/patch-prune-reqs.sh`、`patch-prune2.sh` … `patch-prune9.sh`）：

```bash
B=~/bft-build
TT=$B/tt-inference-server/tt-metal-src
F=$TT/tt_metal/python_env/requirements-dev.txt
prune() { sed -i -E "/^[[:space:]]*$1([[:space:]]*[=<>!~;]|[[:space:]]*$|#)/d" "${2:-$F}"; }

# 轮 1（无 wheel 或 sdist 极重）
for p in numba opencv-python-headless av pyarrow; do prune $p; done
prune pandoc  $TT/docs/requirements-docs.txt          # PyPI 包仅 x86_64 wheel
prune lxml    $TT/docs/requirements-docs.txt          # 无 riscv64 wheel，需 libxml2-dev
prune psycopg2-binary $TT/tests/sweep_framework/requirements-sweeps.txt

# 轮 2（传递依赖 pyarrow / scipy / torchvision / llvmlite）
prune datasets            # -> pyarrow
for p in evaluate torch-fidelity librosa fiftyone open_clip_torch medpy; do prune $p; done

# 轮 3（构建时下载 GitHub Release 二进制）
prune clang-format        # PyPI 包构建时下载 LLVM 二进制（直连 2 KB/s）

# 轮 4
prune tiktoken            # ==0.7.0 旧版 sdist 用 setuptools_rust 后端；vLLM 安装步骤会装新版

# 轮 5（qwen-vl-utils 传递依赖 av，需 ffmpeg 开发库）
prune qwen-vl-utils
sed -i 's|qwen-vl-utils|# qwen-vl-utils (needs av/ffmpeg-dev; skipped on riscv64)|' \
  $TT/models/demos/qwen25_vl/requirements.txt

grep -nE '^(numba|opencv|av|pyarrow|datasets|evaluate|torch-fidelity|librosa|fiftyone|open_clip|medpy|clang-format|tiktoken|qwen-vl-utils)' $F || echo "(clean)"
```

剪枝后 `requirements-dev.txt` 的关键内容（本次最终状态，供比对）：

```
loguru==0.6.0 / pytest-* / protobuf==5.29.6 / transformers == 5.12.1 / huggingface-hub >= 0.30.0
torchmetrics==1.9.0 / timm / diffusers==0.38.0 / accelerate==1.7.0 / peft==0.19.1 / sentencepiece==0.2.1
numpy==2.5.3 / pandas==2.3.3 / matplotlib==3.11.1 / Pillow==12.3.0 / pyyaml / networkx==3.1
...
-r ../../docs/requirements-docs.txt
-r ../../tests/sweep_framework/requirements-sweeps.txt
```

### 6.9 create_venv.sh 补丁（Python 3.12 环境）

四处补丁，**都在 `create_venv.sh` 上**：

**(a) 预装 sdist 构建后端**（`--no-build-isolation` 下后端必须在环境内；文件：`patch-prune2.sh` / `7` / `8` / `9`）

```bash
python3 - $TT/create_venv.sh <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''echo "Installing dev dependencies"'''
new = '''echo "Preinstalling sdist build backends (riscv64: --no-build-isolation needs them in-env)"
uv pip install --extra-index-url "$PYTORCH_INDEX" \\
    --index-strategy unsafe-best-match \\
    scikit-build-core pybind11 maturin setuptools_rust meson-python setuptools_scm flit-core poetry-core hatchling pdm-backend cffi \\
    "cython>=3.0" "setuptools==80" "wheel==0.45.1" "numpy==2.5.3"

echo "Installing dev dependencies"'''
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
```

**(b) 跳过 triage 依赖**（`pycapnp` / `tt-umd` 无 riscv64 wheel，triage 只是调试工具）

```bash
python3 - $TT/create_venv.sh <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''echo "Installing tt-triage dependencies"
uv pip install --index-strategy unsafe-best-match -r "$(pwd)/tools/triage/requirements.txt"'''
new = '''# riscv64: skip tt-triage deps (pycapnp/tt-umd have no riscv64 wheels; triage is a debug tool)
echo "SKIP: tt-triage dependencies (riscv64)"'''
assert old in s
open(p, 'w').write(s.replace(old, new))
PYEOF
```

**(c) 去掉 pytorch 官方索引**（`download.pytorch.org` 索引查询超时，uv 会卡 10 次重试 ≈ 400 s）

```bash
sed -i 's|PYTORCH_INDEX="https://download.pytorch.org/whl/cpu"|PYTORCH_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"|' $TT/create_venv.sh
```

**(d) 补 cffi**（cryptography 的 maturin 构建脚本在 `--no-build-isolation` 下需要环境内 cffi）
Dockerfile 中已用 `sed -i 's/pdm-backend/pdm-backend cffi/' create_venv.sh` 兜底；若手动改过 (a)，也可直接写进清单。

---

## 7. 阶段七：vllm-tt-plugin 适配

作用于 `~/bft-build/tt-inference-server/vllm-tt-plugin-src/docs/install-vllm-tt.sh`。

### 7.1 依赖来源与排除（文件：`bft-scripts/patch-plugin-riscv64.sh`）

```bash
python3 - "$PLUGIN/docs/install-vllm-tt.sh" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()

# 1) common.txt 改从 /mnt/vendor 读取（raw.githubusercontent.com 被墙）
old_fetch = '''VLLM_COMMON_REQUIREMENTS=$(mktemp)
curl -fsSL \\
    https://raw.githubusercontent.com/vllm-project/vllm/v0.30.0/requirements/common.txt \\
    -o "$VLLM_COMMON_REQUIREMENTS" ||'''
new_fetch = '''# riscv64: raw.githubusercontent.com is blocked; use pre-downloaded file bind-mounted at /mnt/vendor
VLLM_COMMON_REQUIREMENTS=$(mktemp)
cp /mnt/vendor/vllm-common.txt "$VLLM_COMMON_REQUIREMENTS" ||
    { echo "install-vllm-tt: cannot read vendored vllm-common.txt"; return 1; }
# riscv64: drop opencv-python-headless (no riscv64 wheel; vLLM guards cv2 with PlaceholderModule)
grep -v '^opencv-python-headless' "$VLLM_COMMON_REQUIREMENTS" > "$VLLM_COMMON_REQUIREMENTS.tmp" && \\
    mv "$VLLM_COMMON_REQUIREMENTS.tmp" "$VLLM_COMMON_REQUIREMENTS"'''
assert old_fetch in s; s = s.replace(old_fetch, new_fetch)

# 2) torchvision 无 riscv64 wheel → best-effort
old_tv = '''uv pip install --no-deps --index-url https://download.pytorch.org/whl/cpu \\
    torchvision==0.26.0   # keep in sync with tt-metal requirements-dev.txt'''
new_tv = '''# riscv64: no torchvision riscv64 wheel exists; only specific VLM processors need it (not Qwen)
uv pip install --no-deps --index-url https://download.pytorch.org/whl/cpu \\
    torchvision==0.26.0 \\
    || echo "WARN: torchvision install failed (expected on riscv64 - no wheel); skipping"'''
assert old_tv in s; s = s.replace(old_tv, new_tv)

# 3) numba 依赖 llvmlite（无 riscv64 wheel）→ 跳过（仅 ngram 投机解码需要）
old_nb = '''uv pip install numba==0.61.2   # matches vLLM's own requirements/cuda.txt pin'''
new_nb = '''# riscv64: llvmlite has no riscv64 wheel; numba is only needed for n-gram speculative decoding
echo "SKIP: numba not installed on riscv64 (llvmlite unavailable; ngram spec-decode unsupported)"'''
assert old_nb in s; s = s.replace(old_nb, new_nb)
open(p, 'w').write(s)
PYEOF
```

### 7.2 vLLM 源码构建（文件：`bft-scripts/patch-plugin-vllm-build.sh`）

vLLM 0.30.0 的 `build-system.requires` 含 `torch==2.13.0`（riscv64 无此 wheel），构建隔离环境无法解析。
改为 `--no-build-isolation` 复用环境内 torch 2.14.0+cpu 与预装后端，并让失败显式中止：

```bash
python3 - "$PLUGIN/docs/install-vllm-tt.sh" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'VLLM_TARGET_DEVICE=empty uv pip install --no-deps --no-binary vllm vllm==0.30.0'
new = '''# riscv64: vLLM's build-system.requires pins torch==2.13.0 (no riscv64 wheel), so the
# isolated build env cannot resolve. --no-build-isolation reuses this env's torch + backends.
uv pip install jinja2 packaging wheel "setuptools>=77.0.3,<81.0.0" setuptools-scm "setuptools-rust>=1.9.0"
VLLM_TARGET_DEVICE=empty uv pip install --no-deps --no-binary vllm --no-build-isolation vllm==0.30.0 ||
    { echo "install-vllm-tt: vLLM source install failed"; return 1; }'''
assert old in s
open(p, 'w').write(s.replace(old, new))
PYEOF
```

### 7.3 vllm-overrides.txt（文件：`bft-scripts/patch-overrides.sh`）

`ttnn` 要求 `numpy<2`，而 vLLM 的 `opencv-python-headless>=4.13.0` 要求 `numpy>=2`；且 opencv 在 riscv64 无 wheel。
用 override 把 opencv 从解析中移除，并把 numpy 下限抬到 2.4（与 wheelhouse 一致）：

```bash
# numpy 覆盖（patch-numpy-pin.sh 已改）
# riscv64: 追加 opencv 永假标记
cat >> "$PLUGIN/docs/vllm-overrides.txt" <<'EOF'

# riscv64: opencv-python-headless has no riscv64 wheel and its sdist build is prohibitive.
# It is pulled in transitively by mistral-common and reached only by vLLM's lazy
# video-IO path (vllm/multimodal/video.py), which is guarded by PlaceholderModule.
opencv-python-headless ; python_version < "3"
EOF
```

---

## 8. 阶段八：构建上下文准备

### 8.1 `.dockerignore`

预克隆源码通过 **命名上下文（`--build-context`）** 注入，不进入主上下文传输，因此加入忽略列表（注意：**不能用
`RUN --mount=type=bind,source=` 引用被 ignore 的目录**，必须用 `from=<命名上下文>`，见 13.3）：

```bash
cat >> ~/bft-build/tt-inference-server/.dockerignore <<'EOF'

# bft-riscv64-sources: pre-cloned sources injected via bind mount, not COPY
tt-metal-src
vllm-tt-plugin-src
tt-smi-src
sfpi-src
vendor
EOF
```

### 8.2 前置文件确认

```bash
cd ~/bft-build/tt-inference-server
ls model_spec.json VERSION vllm-tt-metal/src/run_vllm_api_server.py utils/requirements.txt
# model_spec.json 由仓库自带，runtime 阶段会 COPY 进镜像
```

---

## 9. 阶段九：定制 Dockerfile

文件：`~/bft-build/tt-inference-server/vllm-tt-metal/vllm.tt-metal.src.dev.riscv64.Dockerfile`
（由官方 `vllm.tt-metal.src.dev.Dockerfile` 改造而来，与官方结构保持一致：builder + runtime 两阶段）

**相对官方的 7 处改动**：

| # | 改动 | 原因 |
| --- | --- | --- |
| 1 | `ARG TT_METAL_DOCKERFILE_URL=local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1` | 官方基础镜像无 riscv64 |
| 2 | git 全局 `insteadOf` gh-proxy + PyPI 清华 + `UV_FIND_LINKS=/mnt/wheelhouse` | 网络封锁 |
| 3 | rustup 用预下载 `rustup-init`，`RUSTUP_DIST_SERVER` 指清华 | 引导脚本抖动 |
| 4 | **venv（3.12）在 C++ 编译之前创建**，编译时 `PATH` 前置 venv | 保证 ttnn Python 绑定针对 3.12 |
| 5 | SFPI 走 `BUILD` 路径，`sfpi-src` 从命名上下文注入，可选 `sfpi-prebuilt` 跳过重编 | riscv64 无官方 SFPI 包 |
| 6 | 插件/tt-smi 源码从命名上下文注入；插件安装委托官方 `install-vllm-tt.sh` | 避免重复维护依赖清单 |
| 7 | runtime 阶段 relink venv python 符号链接到 uv-managed 3.12 | 镜像内 system python 是 3.14 |

关键片段（完整文件见 `bft-scripts/vllm.tt-metal.src.dev.riscv64.Dockerfile`）：

```dockerfile
ARG TT_METAL_DOCKERFILE_URL=local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1
FROM ${TT_METAL_DOCKERFILE_URL} AS builder
...
ENV ... \
    CPM_USE_LOCAL_PACKAGES=ON \
    RUSTUP_HOME=/usr/local/rustup  CARGO_HOME=/usr/local/cargo \
    RUSTUP_DIST_SERVER=https://mirrors.tuna.tsinghua.edu.cn/rustup \
    RUSTUP_UPDATE_ROOT=https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup
ENV PYTHONPATH=${TT_METAL_HOME} \
    PYTHON_ENV_DIR=${TT_METAL_HOME}/python_env \
    LD_LIBRARY_PATH=${TT_METAL_HOME}/build/lib

RUN git config --global url."https://gh-proxy.com/https://github.com/".insteadOf https://github.com/
ENV UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple ... UV_FIND_LINKS=/mnt/wheelhouse

# (1) 先建 venv（3.12）+ torch（wheelhouse）
RUN --mount=type=bind,from=tt-metal-src,target=/mnt/tt-metal-src \
    --mount=type=bind,from=wheelhouse,target=/mnt/wheelhouse \
    /bin/bash -c "cp -a /mnt/tt-metal-src ${TT_METAL_HOME} \
    && cd ${TT_METAL_HOME} \
    && sed -i 's/pdm-backend/pdm-backend cffi/' create_venv.sh \
    && ( for i in 1 2 3 4 5; do CXX=clang++-20 CC=clang-20 bash ./create_venv.sh --python-version 3.12 --force && exit 0; \
         echo 'create_venv.sh failed, retrying in 30s'; sleep 30; done; exit 1 ) \
    && source ${PYTHON_ENV_DIR}/bin/activate \
    && if [ -f 'models/demos/qwen25_vl/requirements.txt' ]; then \
         uv pip install -r models/demos/qwen25_vl/requirements.txt || echo 'WARN: qwen25_vl requirements failed'; fi \
    && uv pip install /mnt/wheelhouse/torch-2.14.0+cpu-*.whl"

# (2) C++ 编译（venv 激活 → 绑定 3.12；可选预置 SFPI 包）
RUN --mount=type=bind,from=sfpi-src,target=/mnt/sfpi-src \
    --mount=type=bind,from=sfpi-prebuilt,target=/mnt/sfpi-prebuilt,ro \
    /bin/bash -c "mkdir -p ${TT_METAL_HOME}/runtime \
    && cp -f /mnt/sfpi-prebuilt/*.txz ${TT_METAL_HOME}/runtime/ 2>/dev/null || true \
    && cd ${TT_METAL_HOME} \
    && export PATH=${PYTHON_ENV_DIR}/bin:$PATH \
    && bash ./build_metal.sh --disable-profiler \
    && rm -rf ${TT_METAL_HOME}/.git \
    && rm -rf ${TT_METAL_HOME}/runtime/sfpi/sfpi-src \
    && { uv cache clean || true; }"

# (3) 插件 + vLLM 源码
RUN --mount=type=bind,from=vllm-tt-plugin-src,target=/mnt/vllm-tt-plugin-src \
    --mount=type=bind,from=vendor,target=/mnt/vendor \
    --mount=type=bind,from=wheelhouse,target=/mnt/wheelhouse \
    /bin/bash -c "cp -a /mnt/vllm-tt-plugin-src ${vllm_tt_plugin_dir} \
    && cd ${vllm_tt_plugin_dir} \
    && source ${PYTHON_ENV_DIR}/bin/activate \
    && uv pip install --upgrade pip \
    && source docs/install-vllm-tt.sh \
    && rm -rf ${vllm_tt_plugin_dir}/.git"

# (4) tt-smi（独立 venv，uv-managed 3.12）
RUN --mount=type=bind,from=tt-smi-src,target=/mnt/tt-smi-src \
    /bin/bash -c "cp -a /mnt/tt-smi-src ${TT_SMI_DIR} \
    && cd ${TT_SMI_DIR} \
    && /usr/local/bin/python3.12 -m venv .venv \
    && source .venv/bin/activate \
    && pip3 install --upgrade pip \
    && source ${CARGO_HOME}/env \
    && pip3 install ."

# runtime 阶段：与官方一致（COPY builder 产物 + app + model_spec.json），
# 额外把 venv 的 python 符号链接指向 /usr/local/bin/python3.12（uv-managed 3.12）
```

> 说明：`./build_metal.sh --disable-profiler` 中 `--disable-profiler` 用于跳过 Tracy / WASM viewer 的
> freetype/glad/glew 下载；`KERNEL_COMPILE`（SFPI 编译器）仍在，因为 ttnn 运行期需要 `riscv-tt-elf-g++`。

---

## 10. 阶段十：构建执行

```bash
# 文件：~/bft-build/build-manual.sh
cd ~/bft-build/tt-inference-server

IMAGE_TAG=ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-dev-ubuntu-26.04-riscv64:0.22.0-v0.79.0-rc11-d84049e

DOCKER_BUILDKIT=1 docker build \
  --network host \
  --build-context tt-metal-src=tt-metal-src \
  --build-context sfpi-src=/home/ubuntu/bft-build/sfpi-src \
  --build-context wheelhouse=wheelhouse \
  --build-context vllm-tt-plugin-src=vllm-tt-plugin-src \
  --build-context vendor=vendor \
  --build-context tt-smi-src=/home/ubuntu/bft-build/tt-smi-src \
  --build-context rustup-bin=/home/ubuntu/bft-build/rustup-bin \
  --build-context sfpi-prebuilt=/home/ubuntu/bft-build/sfpi-prebuilt \
  -t "$IMAGE_TAG" \
  --build-arg TT_METAL_COMMIT_SHA_OR_TAG=v0.79.0-rc11 \
  --build-arg TT_VLLM_COMMIT_SHA_OR_TAG=d84049e \
  --build-arg CONTAINER_APP_UID=1000 \
  -f vllm-tt-metal/vllm.tt-metal.src.dev.riscv64.Dockerfile \
  .
echo "MANUAL_BUILD_EXIT=$?"
```

后台执行 + 落盘日志（推荐，构建 2 小时以上）：

```bash
setsid nohup bash ~/bft-build/build-manual.sh > /tmp/build-main.log 2>&1 < /dev/null &
tail -f /tmp/build-main.log
```

### 10.1 步骤与进度对照表（日志行前缀 `#<step>`）

| 步骤 | 内容 | 典型耗时 | 完成标志 |
| --- | --- | --- | --- |
| #1–#16 | 基础镜像层 + 命名上下文加载 | 缓存命中 | `#16 [context ...] DONE` |
| #17–#26 | apt / 用户 / rustup | 2 min（缓存命中时秒过） | `rustc --version`、`cargo --version` 输出 |
| **#27** | `create_venv.sh`（Python 3.12 环境 + torch） | 18–22 min | `Built cryptography==...` → `#27 DONE` |
| **#28** | `build_metal.sh --disable-profiler` | 25–37 min | `Linking CXX shared library .../_ttnn.so` → `#28 DONE` |
| **#29** | 插件 `install-vllm-tt.sh`（含 vLLM 0.30.0 源码） | 35–40 min | `Built vllm==0.30.0` → `Installed 2 packages` → `#29 DONE` |
| **#30** | Quetzal（未启用，直接通过） | 1 s | `Building native-only image (TT_QUETZAL_COMMIT_SHA unset)` |
| **#31** | tt-smi | 6–8 min | `Successfully installed ... tt-smi-3.1.1` → `#31 DONE` |
| #32–#40 | runtime 阶段（apt、COPY、chown、app requirements） | 25–30 min | `#40 DONE` |
| #41–#47 | 导出（naming / unpacking） | 10–15 min | `MANUAL_BUILD_EXIT=0` |

### 10.2 缓存策略

- 构建**按层缓存**：C++ 编译层（#27）一旦成功，后续修复插件层不必重编 tt-metal。
- 但**任何上游层变化都会使下游全部重算**。因此调整顺序原则：
  - 依赖 Python 环境的改动（插件/依赖）放后面；
  - 如果只想改 C++ 侧，必须先确认 `create_venv` 层能命中。
- `tenstorrent` 与 `sfpi` 的预构建物（`sfpi-prebuilt/*.txz`）改变会使 C++ 层重算（可接受）。

---

## 11. 阶段十一：验收

```bash
# 文件：bft-scripts/verify-image.sh + final-check.sh
IMG=ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-dev-ubuntu-26.04-riscv64:0.22.0-v0.79.0-rc11-d84049e

docker run --rm --entrypoint /bin/bash "$IMG" -c '
uname -m && head -2 /etc/os-release
clang --version | head -1
ls $TT_METAL_HOME/build/lib | head -8                      # _ttnn.so _ttnncpp.so libtt_metal.so ...
source $PYTHON_ENV_DIR/bin/activate
python3 --version                                          # 3.12.15
pip list 2>/dev/null | grep -Ei "^(torch|vllm|vllm-tt-plugin|transformers|ttnn) "
python3 -c "import ttnn, vllm, vllm_tt_plugin; print(\"combined import OK\")"
python3 -c "import importlib.metadata as m; print([e for e in m.entry_points(group=\"vllm.platform_plugins\")])" | tail -1
tt-smi -h 2>&1 | head -2
'
```

期望输出要点：

| 检查项 | 期望 |
| --- | --- |
| 架构/系统 | `riscv64` / `Ubuntu 26.04 LTS` |
| tt-metal 产物 | `_ttnn.so`、`_ttnncpp.so`、`libtt_metal.so` 等 |
| Python | `3.12.15` |
| 包版本 | `torch 2.14.0+cpu`、`vllm 0.30.0+empty`、`vllm-tt-plugin 0.1.0`、`transformers 5.12.1`、`ttnn 0.79.0rc12.dev0+gg29f93c91` |
| **ttnn 导入** | `ttnn OK /home/container_app_user/tt-metal/ttnn/ttnn/__init__.py`（**关键**，见 13.4） |
| 插件入口点 | `platform: ["tt"]`、`general: [... "tt_model_registry"]` |
| tt-smi | 正常打印 usage |
| SFPI | `$TT_METAL_HOME/runtime/sfpi/compiler/bin/riscv-tt-elf-g++` 存在 |
| app | `/home/container_app_user/app/{src,utils,VERSION,requirements.txt}` |

---

## 12. 运行镜像

```bash
# 前置（宿主机）：tt-kmd 驱动、1G 大页、tt-flash 固件
sudo modprobe tenstorrent && ls /dev/tenstorrent/        # 应有 0、1（N300 双芯片）
# 1G 大页（约需 4 GiB 预留；数值按教程调整）
echo 4 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
sudo mkdir -p /dev/hugepages-1G
sudo mount -t hugetlbfs -o pagesize=1G none /dev/hugepages-1G

docker run \
  --env "HF_TOKEN=$HF_TOKEN" --ipc host --publish 8000:8000 \
  --device /dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --volume volume_id_Qwen3-8B:/home/container_app_user/cache_root \
  ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-dev-ubuntu-26.04-riscv64:0.22.0-v0.79.0-rc11-d84049e \
  --model Qwen3-8B --tt-device n300
```

或用 `run.py`（自动生成 docker 命令，可用 `--print-docker-cmd` 先看）：

```bash
python3 run.py --model Qwen3-8B --device n300 --workflow server --docker-server \
  --override-docker-image ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-dev-ubuntu-26.04-riscv64:0.22.0-v0.79.0-rc11-d84049e
```

健康检查与压测见《Tenstorrent_N300_Qwen部署教程.md》步骤 7/8。

---

## 13. 故障排查手册（本次实际踩坑全记录）

### 13.1 GitHub 直连被阻断（git clone / raw 文件 / release 资产）

- **现象**：`git clone https://github.com/...` 超时；`curl raw.githubusercontent.com` 无响应；release 资产 2 KB/s。
- **判定**：`api.github.com` 可通，说明是特定域名被限。
- **处置**：git 全局 `insteadOf gh-proxy`；release/raw 走 `https://gh-proxy.com/<原始URL>`；PyPI 换清华；wheel 从 RISE 预下载。
- **注意**：`file(DOWNLOAD)`（CMake）与 `curl`（脚本内）**不受** git insteadOf 影响，需单独改（见 6.4、7.1）。

### 13.2 `download.pytorch.org` 索引超时导致 `create_venv.sh` 卡死

- **现象**：`error: Request failed after 10 retries in 393.6s / Failed to fetch https://download.pytorch.org/whl/cpu/packaging/`
- **处置**：把 `create_venv.sh` 的 `PYTORCH_INDEX` 指向清华（torch 实际来自 wheelhouse）；`UV_HTTP_RETRIES=10`。

### 13.3 `.dockerignore` 会让 `RUN --mount=type=bind,source=` 报 not found

- **现象**：`failed to compute cache key: "/tt-metal-src": not found`
- **原因**：被 `.dockerignore` 排除的目录**不能**作为 bind mount 源（实测 Docker 29.1.3 如此）。
- **处置**：改用**命名上下文**：构建时 `--build-context tt-metal-src=tt-metal-src`，
  Dockerfile 里 `RUN --mount=type=bind,from=tt-metal-src,target=/mnt/tt-metal-src`。
  命名上下文指向 `.dockerignore` 中的**子目录**时不受影响（已实测）；但若指向同一目录（`.`）则会受影响。

### 13.4 `import ttnn` 报 `undefined symbol: PyImport_AddModuleRef`

- **现象**：镜像内 `import ttnn` 失败：
  `/home/container_app_user/tt-metal/ttnn/ttnn/_ttnn.so: undefined symbol: PyImport_AddModuleRef`
  （该符号是 CPython 3.13 才引入的 API）
- **原因**：`build_metal.sh` 用 `command -v python3` 决定绑定解释器 —— 若编译时没有 venv，
  用的是系统 Python 3.14；而 venv 必须是 3.12（riscv64 torch 只有 cp312 wheel）。
- **处置（两种，推荐前者）**：
  1. **先建 venv、编译时 `export PATH=${PYTHON_ENV_DIR}/bin:$PATH`**（本次采用的方案）；
  2. 在已有构建目录上 `cmake -B build_Release -DPython3_EXECUTABLE=...` 重配后只重建 `_ttnn.so`
     —— **不可行**：重配会因 `install TARGETS tt-logger does not exist`、`WRITE_BASIC_CONFIG_VERSION_FILE
     No VERSION`（此时 `.git` 已删、CPM 本地包状态不一致）而失败，需从头构建。

### 13.5 ThinLTO 链接：mold 需要 `LLVMgold.so`

- **现象**：`ld.mold: cannot open LLVMgold.so` / ThinLTO link 失败
- **处置**：工具链设 `set(CMAKE_LINKER_TYPE LLD)`；基础镜像装 `lld-20`（而非 `llvm-20-linker-tools`）。

### 13.6 riscv64 无 AVX2

- **现象**：`spsc_marker_decode.hpp` 编译报 `_mm256_*` 未定义
- **处置**：改 simde（见 6.6）。若 simde 版 `maskload` 报错，掩码指针类型用 `const int64_t*`。

### 13.7 `--no-build-isolation` 下缺构建后端（连环坑）

按报错顺序会出现以下提示，逐个补进预装清单即可：

| 报错 | 缺失后端 | 涉及包 |
| --- | --- | --- |
| `No module named 'scikit_build_core'` | scikit-build-core | pyarrow（经 datasets）、sentencepiece |
| `No module named 'setuptools_scm'` | setuptools_scm | pyarrow |
| `No module named 'setuptools_rust'` | setuptools_rust | tiktoken 0.7.0 |
| `meson-python` 相关 | meson-python | contourpy |
| `No module named 'cffi'` | cffi | cryptography（maturin 构建脚本） |

最终预装清单见 6.9(a)。**注意**：这些 sdist 本身（pyarrow/datasets 等）仍应剪枝，否则会真的去编译。

### 13.8 传递依赖把被剪掉的包又拉回来

- 例：剪掉 `pyarrow` 后，`datasets` 与 `evaluate → datasets` 又把它拉回；剪掉 `numba` 后 `librosa` 仍需要它。
- **处置**：按“依赖链根部剪枝”：`datasets`、`evaluate`、`librosa`、`fiftyone`、`open_clip_torch`、`medpy`、
  `qwen-vl-utils`（→`av`）、`torch-fidelity`（→`scipy`）。

### 13.9 PyPI 包在构建时下载 GitHub Release 二进制

- **现象**：`clang-format==19.1.4` 构建失败（其 wheel 构建过程要下载 LLVM 二进制）。
- **处置**：剪掉（代码格式化工具，运行期不需要）。同类需警惕：`ninja`、`cmake` 的 sdist 版本。

### 13.10 SFPI 构建时间与失败点

- 源码构建约 75 分钟（`sfpi-build.log` 约 11 MB）；需要 `autoconf/automake/bison/expect/flex/gawk/texinfo`。
- 若 `.git` 不存在且没有预置源码，会尝试 `git clone` → 直连失败。必须保证 `~/bft-build/sfpi-src` 含 `.git` 与子模块，
  或提供 `sfpi-prebuilt/*.txz`。
- 生成的包落在 `$TT_METAL_HOME/runtime/sfpi_7.78.0_riscv64_debian.txz`（**注意是 runtime/ 而非 runtime/sfpi/**），
  CMake 侧判断逻辑为：存在该 txz 则跳过构建、直接解包。

### 13.11 构建期间 SSH 断连导致命令悬挂

- **现象**：长命令（`sleep 235; tail ...`）无输出超时被取消。
- **处置**：长任务一律 `setsid nohup ... > /tmp/xxx.log 2>&1 < /dev/null &`，用短命令轮询日志
  （本次 `restart-build.sh`、`start-venv-test.sh` 即为此模式）。

### 13.12 runtime 阶段 chown 很慢（25–30 min）

- `COPY --from=builder` 后会 `chown -R` 整棵 tt-metal 树（十几万文件，~10 GB）。
- 优化：无（属官方 Dockerfile 行为）；预留时间即可。

---

## 14. 附录 A：完整脚本清单（工作区 `bft-scripts/`）

| 文件 | 用途 |
| --- | --- |
| `base.Dockerfile` | 基础镜像定义（5.2） |
| `build-manual.sh` | 主镜像构建入口（10） |
| `vllm.tt-metal.src.dev.riscv64.Dockerfile` | 定制 Dockerfile（9） |
| `fetch-rustup-init.sh` | 预下载 rustup-init（2.3） |
| `fetch-rise-wheels.sh` / `fetch-rise-wheels2.sh` | 下载 RISE riscv64 wheel（4.1） |
| `fetch-sfpi-submodules.sh` | SFPI 子模块拉取（3.4） |
| `prep-context.sh` | vendor + .dockerignore（8.1） |
| `patch-ttmetal-riscv64.sh` | 工具链文件 / sfpi-info.sh / build_metal.sh（6.1–6.3） |
| `patch-cpm.sh` | CPM 预置与引导补丁（6.4） |
| `patch-linker.sh` | LLD 链接器 + ThinLTO 自测（6.5） |
| `patch-simde-sprof.sh` / `patch-simde-sprof2.sh` | streaming profiler → simde（6.6） |
| `patch-numpy-pin.sh` | numpy/matplotlib pin（6.7） |
| `patch-prune-reqs.sh` … `patch-prune9.sh` | 依赖剪枝（6.8） |
| `patch-create-venv*.sh` | create_venv.sh 补丁（6.9） |
| `patch-plugin-riscv64.sh` / `patch-plugin-vllm-build.sh` / `patch-overrides.sh` | 插件与 vLLM 构建（7） |
| `extract-sfpi-prebuilt.sh` | 提取 SFPI 预构建包（4.4） |
| `verify-image.sh` / `final-check.sh` | 验收（11） |
| `host-create-venv-test.sh` / `host-plugin-test.sh` | 先在宿主机快速迭代 Python 依赖（可选，见附录 B） |

## 15. 附录 B：先在宿主机预跑 Python 依赖（强烈推荐）

TT-metal 的 C++ 编译很贵，Python 依赖的坑应在宿主机上先趟完（同一份源码、同一镜像源）：

```bash
export UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
export UV_FIND_LINKS=~/bft-build/tt-inference-server/wheelhouse
export UV_PYTHON_INSTALL_DIR=~/uv-python-test
export UV_PYTHON_INSTALL_MIRROR=https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download
cd ~/bft-build/tt-inference-server/tt-metal-src
bash ./create_venv.sh --env-dir /tmp/tt-test-venv --python-version 3.12
# 再在 /tmp/tt-test-venv 中预跑：
#   source /tmp/tt-test-venv/bin/activate
#   VLLM_TARGET_DEVICE=empty uv pip install --no-deps --no-binary vllm --no-build-isolation vllm==0.30.0
```

这样能把“缺后端 / 缺 wheel / 依赖冲突”在十几分钟内迭代完，避免每次浪费 30 分钟的 C++ 重编。

## 16. 已知限制

1. **riscv64 缺失的组件**：`torchvision`（无 wheel）、`numba`（ngram 投机解码不可用）、
   `opencv-python-headless`（仅 vLLM 视频 IO 懒加载路径）、`qwen-vl-utils`+`av`（需 ffmpeg 开发库）。
   Qwen 文本/图像推理路径不受影响。
2. **镜像未做端到端推理验证**：构建机无 `/dev/tenstorrent`、无 `tt-kmd`，仅做组件级验收；
   上卡后需按教程验证首个请求与 trace capture。
3. **SFPI 包复用**：若使用 `sfpi-prebuilt/`，该工具链并非本次构建过程内新编译（但确由同机源码构建产生）；
   完全从零复现请删除该目录。
4. **`CONTAINER_APP_UID=1000`**：与教程 `--image-user 1000` 一致；自定义 UID 需同时改构建参数与运行参数。
5. **numpy 2.x**：tt-metal 上游要求 `numpy<2`，本次放宽到 2.5.3 以使用 riscv64 wheel，
   已核查 ttnn/tt_metal 无 numpy 1.x 专有 API 用法；后续升级需复检。

---

## 17. 附录 C：一页式复现检查清单

按顺序勾选；每条命令均为可直接执行的形式（`$B=~/bft-build`）。

```bash
export B=~/bft-build
```

| # | 检查项 | 命令 / 动作 | 通过标准 |
| --- | --- | --- | --- |
| 0 | 系统基线 | `nproc; free -g; df -h /; lsb_release -cs` | 80 核 / 121G / ≥600G 可用 / `resolute` |
| 1 | Docker + debootstrap | `docker buildx version; debootstrap --version` | 均有输出 |
| 2 | 网络策略 | 见 1（api.github 可达、github 直连不通） | 4 条策略确认 |
| 3 | git 改写 | `git config --global --get-regexp insteadof` | 指向 gh-proxy |
| 4 | pip 镜像 | `cat ~/.pip/pip.conf` | 清华索引 |
| 5 | 5 个仓库 | `ls $B` | `tt-inference-server sfpi-src tt-smi-src rustup-bin` |
| 6 | 子模块 | `du -sh $B/sfpi-src`、`ls $B/tt-inference-server/tt-metal-src/tt_metal` | 2.0G / 目录非空 |
| 7 | wheelhouse | `ls $B/tt-inference-server/wheelhouse` | 5 个 cp312 riscv64 wheel |
| 8 | vendor | `wc -l $B/tt-inference-server/vendor/vllm-common.txt` | ≈60 行 |
| 9 | CPM | `sha256sum $B/tt-inference-server/tt-metal-src/.cpmcache/cpm/CPM_0.40.2.cmake` | `c8cdc32c...835d` |
| 10 | rustup-init | `$B/rustup-bin/rustup-init --version` | 正常输出 |
| 11 | 基础 rootfs | `docker images local/ubuntu` | `26.04-riscv64` 208 MB |
| 12 | 基础镜像 | `docker images local/tt-metal` | `...ubuntu-26.04-riscv64:v1` ≈5.5 GB |
| 13 | 基础镜像验收 | 见 5.3 命令块 | clang 20.1.8 / boost 1_90 / py3.12.15 |
| 14 | 工具链文件 | `grep -n 'LLD\|riscv64' $B/tt-inference-server/tt-metal-src/cmake/riscv64-*.cmake` | `CMAKE_SYSTEM_PROCESSOR "riscv64"` + `CMAKE_LINKER_TYPE LLD` |
| 15 | build_metal 工具链 | `grep -n toolchain_path $B/tt-inference-server/tt-metal-src/build_metal.sh` | 指向 riscv64 文件 |
| 16 | SFPI 适配 | `grep -n '/mnt/sfpi-src' $B/tt-inference-server/tt-metal-src/tt_metal/sfpi-info.sh` | 命中预置分支 |
| 17 | CPM 引导补丁 | `grep -n 'skip download' $B/tt-inference-server/tt-metal-src/cmake/CPM.cmake` | 命中 |
| 18 | simde | `grep -c 'simde_mm' $B/tt-inference-server/tt-metal-src/tt_metal/impl/streaming_profiler/spsc_marker_decode.hpp` | > 0 |
| 19 | requirements 剪枝 | 见 6.8 末尾 `grep` | 输出 `(clean)` |
| 20 | create_venv 补丁 | `grep -n 'Preinstalling sdist build backends\|SKIP: tt-triage' $B/tt-inference-server/tt-metal-src/create_venv.sh` | 两处命中 |
| 21 | 插件补丁 | `grep -n 'mnt/vendor/vllm-common.txt\|no-build-isolation\|SKIP: numba' $B/tt-inference-server/vllm-tt-plugin-src/docs/install-vllm-tt.sh` | 三处命中 |
| 22 | overrides | `tail -3 $B/tt-inference-server/vllm-tt-plugin-src/docs/vllm-overrides.txt` | `opencv-python-headless ; python_version < "3"` |
| 23 | .dockerignore | `tail -6 $B/tt-inference-server/.dockerignore` | 含 5 个源码目录 |
| 24 | 构建 | `setsid nohup bash $B/build-manual.sh > /tmp/build-main.log 2>&1 &` | 日志出现 `#27`…`#31` |
| 25 | 构建结束 | `grep MANUAL_BUILD_EXIT /tmp/build-main.log` | `MANUAL_BUILD_EXIT=0` |
| 26 | 镜像存在 | `docker images | grep riscv64` | 15 GB |
| 27 | 验收 | 见 11 命令块 | `ttnn OK` + `combined import OK` |
| 28 | 上卡运行 | 见 12 | `/v1/models` 返回 200 |

> 若在第 24 步某层失败：先看日志确定是 venv(#27)/C++(#28)/插件(#29)/tt-smi(#31)/runtime(#32+) 哪一层，
> 再对照第 13 节故障手册；**修复后直接重跑 `build-manual.sh` 即可，已完成层会自动命中缓存**。

