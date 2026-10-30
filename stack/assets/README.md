# 离线资产（RISCV-Porting）

| 文件 | 用途 | 获取方式 |
| --- | --- | --- |
| `wheelhouse.sha256` | 5 个 riscv64 cp312 wheel 的校验和（torch 2.14.0+cpu / numpy 2.5.3 / pandas 2.3.3 / matplotlib 3.11.1 / pillow 12.3.0） | 01-fetch 从 RISE 索引下载并校验 |
| `rustup-init.sha256` | rustup-init（riscv64gc）校验和 | 01-fetch 从 rust-lang release 下载并校验 |
| `vllm-common.txt` | vLLM 0.30.0 `requirements/common.txt` 快照（raw.githubusercontent.com 被墙时的替代） | 已 vendor，无需下载 |
| `CPM_0.40.2.cmake` | CPM 引导文件（避免构建期从 GitHub 下载） | 已 vendor（sha256 `c8cdc32c…835d`） |
| `sfpi-prebuilt/sfpi_7.78.0_riscv64_debian.txz` | **SFPI 交叉工具链预构建包（默认使用）** | 由 `upstream/sfpi` 7.78.0 源码在 riscv64 主机构建；见下表 |
| `sfpi-prebuilt/*.txz.sha256` | 上述包的校验和（workdir 阶段预检） | 随包提交 |

## SFPI 预构建包说明

- **来源**：`sfpi-info.sh BUILD` 路径（binutils → gcc → newlib）在
  Ubuntu 26.04 / riscv64 上编译，版本 pin 7.78.0（与 tt-metal v0.79.0-rc11 一致）。
- **包内是什么**：`riscv-tt-elf-*` 交叉工具链（面向 Tensix 核的 rv32i 目标），
  其自身二进制是 riscv64 主机可执行文件，仅动态依赖 glibc。
- **使用条件**（`02-workdir.sh` 会预检，不满足自动回退源码编译）：
  1. 主机架构 riscv64（`uname -m`）；
  2. host glibc ≥ 2.38（实测二进制引用的最高符号版本；Ubuntu 24.04+/Debian 13+）；
  3. OS 家族为 debian 系（`/etc/os-release` 的 `ID_LIKE`）；RHEL 系需另建 `_redhat` 包；
  4. SFPI 版本 pin 与 tt-metal 期望一致（文件名逐字匹配 `sfpi-info.sh` 的计算结果）。
- **手工替换**：覆盖 `sfpi-prebuilt/` 下的 txz 与 `.sha256`，并同步 `manifest.yaml` 记录。
- **许可**：包内含 GCC/binutils（GPL）。再分发时须提供对应源码获取方式 —— 本仓库通过
  `upstream/sfpi` 子模块 pin（tag 7.78.0，含 binutils/gcc/newlib 子模块）满足。

镜像分发建议（见 docs/RELEASES.md）：wheelhouse 打包与 SFPI 工具链 txz 可同时作为 GitHub Releases 附件；
15 GB 主镜像走 GHCR。
