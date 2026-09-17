#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
BUILD_DIR="${2:-$ROOT/artifacts/turnip-mesa-26.2.2-v035}"
OUT_DIR="${3:-$ROOT/release-turnip-autotune-v035}"
BASE="$ROOT/scripts/92_package_turnip_a619_persistent_module.sh"
TMP="$ROOT/.tmp-95-package-turnip-autotune-directlog.sh"

[ -f "$BASE" ] || { echo "missing base package script: $BASE" >&2; exit 2; }
cp "$BASE" "$TMP"
trap 'rm -f "$TMP"' EXIT

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()

old_version = "version=0.32-vk1.4-syncmerge-fix"
new_version = "version=0.35-vk1.4-autotune-directlog"
count = text.count(old_version)
if count != 2:
    raise SystemExit(f"v0.35 package version anchor count: {count}")
text = text.replace(old_version, new_version)

repls = [
    ("versionCode=44", "versionCode=48"),
    (
        "description=A52 Turnip Vulkan 1.4 v0.32 sync-merge fix. Retains v0.31 efficiency policy and fixes Mesa 26.2.2 KGSL mixed timestamp/sync-FD merge bugs that caused a release-build null dereference in Warframe.",
        "description=A52 Turnip Vulkan 1.4 v0.35 diagnostic build from the confirmed v0.32 functional baseline. Rendering policy is unchanged; autotune init, renderpass entry/early-return decisions, and bandwidth GMEM/SYSMEM decisions are logged directly through Android liblog with tag TGAT."
    ),
]
for old, new in repls:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"v0.35 package metadata anchor count for {old!r}: {count}")
    text = text.replace(old, new, 1)

p.write_text(text)
PY

chmod +x "$TMP"
"$TMP" "$ROOT" "$BUILD_DIR" "$OUT_DIR"

OLD="$OUT_DIR/touchGrass-Turnip-A619-Mesa-26.2.2-KGSL-Vulkan-1.4-PERSISTENT-KSU.zip"
NEW="$OUT_DIR/touchGrass-Turnip-A619-Mesa-26.2.2-v0.35-AUTOTUNE-DIRECTLOG-DIAG-KSU.zip"
[ -s "$OLD" ] || { echo "expected persistent module zip missing: $OLD" >&2; exit 3; }
mv "$OLD" "$NEW"

echo "v035_package=$NEW"
