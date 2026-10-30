#!/usr/bin/env python3
"""Read targets.<arch>.kernels from manifest.yaml and print a space separated list."""
import re
import sys


def main() -> int:
    if len(sys.argv) < 3:
        return 2
    path, arch = sys.argv[1], sys.argv[2]
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return 1
    in_targets = in_arch = False
    for ln in lines:
        if not in_targets:
            if ln.strip() == "targets:":
                in_targets = True
            continue
        if ln and not ln.startswith(" "):
            break
        if ln.startswith("  ") and not ln.startswith("    ") and ln.strip().endswith(":"):
            in_arch = ln.strip() == arch + ":"
            continue
        if in_arch and "kernels:" in ln:
            m = re.search(r"\[(.*?)\]", ln)
            if m:
                items = [x.strip().strip("\"'") for x in m.group(1).split(",")]
                print(" ".join(i for i in items if i))
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
