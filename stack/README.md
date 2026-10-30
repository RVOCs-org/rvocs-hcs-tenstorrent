# stack/ — Tenstorrent 推理镜像

把 TT-Metal / TT-NN + vLLM + vllm-tt-plugin + tt-smi 构建成可部署的
vLLM OpenAI 兼容推理镜像；支持 **riscv64 源码构建**（`patches/riscv64/` 移植层）
与 **x86_64 官方构建路径**。

产物命名：`rvocs-vllm-tt-<arch>:<version>`（如 `rvocs-vllm-tt-riscv64:v0.1.0`），
`<arch>` 为 OCI 名，`<version>` 来自仓库根的 `VERSION`。

> 宿主机驱动与工具（tt-kmd / tt-smi / tt-flash / tt-topology / 大页）在
> 同仓库的 [`../host/`](../host/)，本部分只负责镜像。

## 版本矩阵（当前 pin）

| 组件 | 仓库 | 版本 |
| --- | --- | --- |
| tt-inference-server | tenstorrent/tt-inference-server | `0da24a9debc2`（0.22.0 系提交） |
| tt-metal（TT-NN/Metalium） | tenstorrent/tt-metal | v0.79.0-rc11（`29f93c91`） |
| vllm-tt-plugin | tenstorrent/vllm-tt-plugin | `d84049e`（内部 pin vLLM 0.30.0） |
| vLLM | vllm-project/vllm | 0.30.0（源码编译） |
| sfpi 交叉工具链 | tenstorrent/sfpi | `fe971db5`（7.78.0 系） |
| tt-smi（镜像内） | tenstorrent/tt-smi | v3.1.1 |
| Python / torch | — | 3.12.15 / 2.14.0+cpu（RISE riscv64 wheel） |

精确 pin 由 `upstream/` 下的 git 子模块承载（见 `.gitmodules` 与 `manifest.yaml`），
用 `scripts/tools/baseline.sh status / apply / check` 管理基线。

## 单分支模型

`master` 单分支：构建脚本、文档、CI 与全部移植层共存——
`patches/riscv64/`（riscv64 源码补丁）、`patches/x86_64/`（x86 补丁）、
`docker/`（基础镜像与主镜像 Dockerfile）、`assets/`（riscv64 离线资产与校验和）。
（历史沿革：riscv64 移植层曾在 `RISCV-Porting` 分支，已折入 master。）

## 快速开始

### 用户：使用现成产物

```bash
# 1) 裸机安装驱动与工具（见 ../host/）
../rvocs-main/rvocs.sh --target tt-host --arch riscv --install --yes

# 2) 拉取镜像并启动 vLLM OpenAI 兼容服务
../rvocs-main/rvocs.sh --target tt-stack --arch riscv --download
../rvocs-main/rvocs.sh --target tt-stack --deploy --yes
```

或直接 `docker run`（等价形式）：

```bash
docker run --ipc host --publish 8000:8000 \
  --device /dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --volume volume_id_Qwen3-8B:/home/container_app_user/cache_root \
  rvocs-vllm-tt-riscv64:v0.1.0 \
  --model Qwen3-8B --tt-device n300
```

### 开发者：一键源码构建（riscv64 主机）

```bash
git clone <this-repo> && cd rvocs-hcs-tenstorrent/stack
git submodule update --init          # 或交给 build.sh 完成

./scripts/build.sh --proxy auto      # fetch → workdir → base → image → verify
# 常用变体：
#   ./scripts/build.sh --stage workdir        # 只重建工作区（重新打补丁）
#   ./scripts/build.sh --stage image          # 只重建镜像
#   ./scripts/build.sh --stage verify         # 只做验收
```

## 阶段

| 阶段 | 作用 |
| --- | --- |
| `fetch` | 初始化/同步 5 个上游子模块（浅克隆，跳过无关嵌套子模块） |
| `workdir` | 物化源码到工作区并按序应用 `patches/<arch>/`（幂等，`--revert` 可回退） |
| `base` | 构建 tt-metalium 基础镜像（riscv64）或拉取官方基础镜像 |
| `image` | 构建主镜像（uv venv、python 依赖、源码安装 tt-metal/plugin） |
| `verify` | 容器内冒烟（导入 ttnn / vllm、版本一致性；`GPU_RUN=1` 真卡冒烟） |

`--stage` 支持组合（如 `--stage "workdir image"`）。

## 结构

```
stack/
├── manifest.yaml            # 上游 pin / 镜像 / 补丁说明（唯一 pin 输入）
├── patches/
│   ├── riscv64/<组件>/series   # riscv64 移植层（单分支）
│   └── x86_64/<组件>/series    # x86_64 补丁
├── docker/                  # 基础镜像与主镜像 Dockerfile
├── assets/riscv64/          # SFPI 预构建包、wheelhouse 清单、rustup pin
├── scripts/
│   ├── build.sh             # 阶段调度
│   ├── 01-fetch.sh … 05-verify.sh
│   ├── lib/common.sh
│   └── tools/baseline.sh    # 基线管理
├── upstream/                # 5 个上游子模块
└── docs/{BUILD,PORTING}.md
```

## 已知限制

- 端到端推理尚未在真实卡上验证（验收止于 ttnn / vLLM 导入与镜像内冒烟）；
- riscv64 需要 glibc ≥ 2.38 才能用预构建 SFPI 包（否则容器内源码编译，+90 min）；
- 嵌套子模块中与镜像无关的（Mooncake、tt-llm-engine）按 `IGNORED_SUBMODULES` 跳过。
