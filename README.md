# rvocs-hcs-tenstorrent

RVOCs 的 **Tenstorrent 厂商仓库**（`rvocs-hcs-{vendor}` 命名）。单分支（`master`），
两个可独立使用的部分：

| 部分 | 作用 | 产物 |
|---|---|---|
| [`host/`](host/) | 宿主机依赖：tt-kmd 内核驱动（DKMS）、tt-smi / tt-flash / tt-topology、1G 大页、udev 规则 | `host/dist/rvocs-tt-deps_<version>_<debarch>.tar.zst` / `.deb` |
| [`stack/`](stack/) | 设备栈镜像：TT-Metal + vLLM 源码构建（riscv64 走 `stack/patches/riscv64/` 移植层） | `rvocs-vllm-tt-<arch>:<version>` |

架构差异一律放在各部分自己的 `patches/<arch>/` 层，不设移植分支。

## 快速开始

```bash
# 构建宿主机依赖包（host/）
./scripts/build.sh --part host --arch riscv64

# 构建推理镜像（stack/）
./scripts/build.sh --part stack --arch riscv64

# 两者按序执行
./scripts/build.sh --part all --arch riscv64
```

`--part` 之后的参数原样透传给该部分自己的 `scripts/build.sh`
（见 `host/scripts/build.sh --help` 与 `stack/scripts/build.sh --help`）。

推荐通过编排层使用（自动处理发现、下载与部署）：

```bash
../rvocs-main/rvocs.sh --target tt-host --arch riscv --install --yes   # -> host/
../rvocs-main/rvocs.sh --target tt-stack  --arch riscv --build            # -> stack/
../rvocs-main/rvocs.sh --target tt-stack  --deploy --yes
```

宿主机 `.deb` 包通过 `--download` / `--install` 获取（资产暂托管在 Gitee Releases，迁移到 GitHub 后链接同步切换）；
镜像发布在华为云 SWR（`swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/`）。

## 基线切换

各部分的 `manifest.yaml` 是唯一 pin 输入：

```bash
./host/scripts/tools/baseline.sh  status | apply | check
./stack/scripts/tools/baseline.sh status | apply | check
```

详见 RVOCs 使用说明「基线切换」一章。

## 版本

仓库版本在根目录 `VERSION`（当前 `v0.1.0`），同时用于 `host/` 交付包与 `stack/` 镜像命名。
厂商级汇总（产物清单、两部分的 pin 概览）见 [manifest.yaml](manifest.yaml)；
权威 pin 分别在 [`host/manifest.yaml`](host/manifest.yaml)（sources）与
[`stack/manifest.yaml`](stack/manifest.yaml)（upstream 子模块 gitlink）。

## 目录结构

```
rvocs-hcs-tenstorrent/
├── host/         # 原 tt-installer（tt-dependency-installer），即 target tt-host；提交历史保留
│   ├── scripts/  # 01-fetch … 06-verify-bundle
│   ├── patches/  # {common,riscv64,x86_64}/<component>/series
│   └── packaging/ # install.sh / udev / systemd / hugepages
├── stack/        # 原镜像仓库（master + RISCV-Porting 已合并）
│   ├── scripts/  # 01-fetch … 05-verify
│   ├── patches/  # {riscv64,x86_64}/<component>/series
│   ├── docker/   # 基础镜像与主镜像 Dockerfile
│   ├── assets/   # riscv64 离线资产（SFPI 预构建包、wheelhouse 清单）
│   └── upstream/ # 5 个上游子模块（tt-inference-server / tt-metal / …）
├── scripts/build.sh   # 薄入口：--part host|stack|all
├── manifest.yaml      # 厂商级汇总
└── VERSION
```

## 历史

- `host/` 由原 `tt-installer`（tt-dependency-installer）仓库整体迁入，即编排层的 target `tt-host`，提交历史作为合并祖先保留；
- `stack/` 由原 `tenstorrent` 镜像仓库迁入，其 `RISCV-Porting` 分支已折入 `master`
  （riscv64 移植层在 `stack/patches/riscv64/`），`patches/x86_64/` 保留；
- 原 `tt-installer`（今 `tt-host`）与 `tenstorrent` 镜像仓库（今 `tt-stack`）已归档只读，请勿继续在其上提交。
