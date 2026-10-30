#!/usr/bin/env bash
# Stage 5: image acceptance (component smoke tests)
#   checks: arch/system, tt-metal build output, the Python 3.12 venv,
#   the combined ttnn+vllm+vllm_tt_plugin import, plugin entry point, tt-smi, SFPI toolchain
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd docker
IMG="$IMAGE_TAG"

docker image inspect "$IMG" >/dev/null 2>&1 || die "image not found: $IMG (run --stage image first)"

INNER=$(cat <<'EOS'
set -e
fail=0
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  [OK]   $desc"; else echo "  [FAIL] $desc"; fail=1; fi
}

echo "== system =="
check "arch is $ARCH"          test "$(uname -m)" = "$ARCH"
echo "  os: $(head -1 /etc/os-release)"

echo "== tt-metal build output =="
check "_ttnn.so"            test -f "${TT_METAL_HOME}/build/lib/_ttnn.so"
check "_ttnncpp.so"         test -f "${TT_METAL_HOME}/build/lib/_ttnncpp.so"
check "SFPI cross compiler"      test -x "${TT_METAL_HOME}/runtime/sfpi/compiler/bin/riscv-tt-elf-g++"

echo "== python environment =="
source "${PYTHON_ENV_DIR}/bin/activate"
check "Python 3.12"         python3 -c "import sys; assert sys.version_info[:2] == (3, 12)"
# The torch pin follows the arch: riscv64 uses the 2.14 CPU wheel we build,
# x86_64/aarch64 take tt-metal's own pin (2.11) from the PyPI CPU index.
case "$ARCH" in
  riscv64) TORCH_PIN=2.14 ;;
  *)       TORCH_PIN=2.11 ;;
esac
check "torch $TORCH_PIN"    python3 -c "import torch; v=torch.__version__; print('  torch:', v); assert v.startswith('$TORCH_PIN'), v"
check "vllm 0.30.0"         python3 -c "import vllm; assert vllm.__version__.startswith('0.30')"
check "vllm-tt-plugin"      python3 -c "import vllm_tt_plugin"
check "ttnn import"            python3 -c "import ttnn"
check "combined import ttnn+vllm"   python3 -c "import ttnn, vllm, vllm_tt_plugin"

echo "== vLLM plugin entry point =="
check "platform_plugins:tt" python3 -c "
import importlib.metadata as m
eps = [e.name for e in m.entry_points(group='vllm.platform_plugins')]
assert 'tt' in eps"

echo "== tt-smi =="
check "tt-smi is usable"         test -x /home/container_app_user/tt-smi/.venv/bin/tt-smi

echo "== app entry =="
check "run_vllm_api_server.py" test -f "${HOME}/app/src/run_vllm_api_server.py"

if [ "$fail" = 0 ]; then echo "VERIFY_OK"; else echo "VERIFY_FAILED"; exit 1; fi
EOS
)

log "verifying image: $IMG"
docker run --rm --entrypoint /bin/bash -e ARCH="$ARCH" "$IMG" -c "$INNER"
log "acceptance passed"
