# 补丁目录（按架构分离）

```
patches/
├── common/                     # 两个架构都应用（能通用就放这里，避免重复）
│   ├── tt-kmd/series
│   ├── tt-umd/series
│   ├── tt-smi/series
│   ├── tt-flash/series
│   └── tt-topology/series
├── riscv64/                    # 仅 riscv64
│   └── <组件>/series
└── x86_64/                     # 仅 x86_64
    └── <组件>/series
```

应用顺序：**`common/<组件>` → `<arch>/<组件>`**（同一组件内按 `series` 里列出的先后顺序）。

`series` 格式：一行一个补丁文件名，`#` 开头为注释，空行忽略（BOM/CRLF 自动清理）。

## 为什么按架构分目录，而不是开分支

- 本仓库的架构差异几乎都落在**补丁**上：`--arch` 已贯穿脚本、`install.sh` 与架构无关、
  wheelhouse 的"无 wheel 即源码构建"已覆盖架构差异；
- 单分支可以避免脚本/文档在两份之间漂移（镜像仓库用分支后需人工双向同步文件）；
- 两个架构共用一份构建逻辑，CI 可以同时验证 `--arch x86_64` 与 `--arch riscv64`。
- **只有当脚本逻辑本身需要分叉**（例如 riscv 需要完全不同的驱动安装流程，或产物形态不同），
  才考虑新开 `RISCV-Porting` 分支，且分支内应只允许改 `patches/riscv64/**` 与
  `manifest.yaml` 的 `ref_by_arch`，并加检查：
  `git diff --quiet master -- scripts packaging || exit 1`。

## 两步执行

```bash
./scripts/build.sh --stage fetch          # ① 只拉官方源码到 work/src
./scripts/build.sh --stage patch          # ② 应用 common + <arch> 补丁（先重置工作树）
./scripts/build.sh --stage patch --revert # 回退到官方源码
./scripts/build.sh --no-patch             # 完全不应用补丁
```

## 补丁如何影响构建

| 组件 | 有补丁时的行为 |
| --- | --- |
| `tt-umd` / `tt-smi` / `tt-flash` / `tt-topology` | `wheels` 阶段用源码构建 wheel，并覆盖同版本 PyPI wheel |
| `tt-kmd` | 补丁进入 DKMS 源码包与预编译 `.ko` |

## 新增一个补丁

```bash
./scripts/build.sh --stage fetch

cd work/src/tt-umd
vim <file>
git diff > ../../../patches/riscv64/tt-umd/0001-fix-xxx.patch     # 架构专用
# 或 ../../../patches/common/tt-umd/0001-fix-xxx.patch            # 通用

echo 0001-fix-xxx.patch >> ../../../patches/riscv64/tt-umd/series
cd - && ./scripts/build.sh --stage patch        # 验证能干净应用
./scripts/build.sh --stage "wheels kmd bundle verify"
```

注意事项：

- 补丁必须基于 `manifest.yaml` 里 pin 的版本（或 `ref_by_arch` 指定的版本）生成；
- 一个补丁只做一件事，便于版本升级后 rebase；
- 同一改动若两个架构都需要，放 `common/`；只有一边需要才放对应架构目录。
