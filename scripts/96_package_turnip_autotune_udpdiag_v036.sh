#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
BUILD_DIR="${2:-$ROOT/artifacts/turnip-mesa-26.2.2-v036}"
OUT_DIR="${3:-$ROOT/release-turnip-autotune-v036}"
BASE="$ROOT/scripts/92_package_turnip_a619_persistent_module.sh"
TMP="$ROOT/.tmp-96-package-turnip-autotune-udpdiag.sh"

[ -f "$BASE" ] || { echo "missing base package script: $BASE" >&2; exit 2; }
cp "$BASE" "$TMP"
trap 'rm -f "$TMP"' EXIT

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()

old_version = "version=0.32-vk1.4-syncmerge-fix"
new_version = "version=0.36-vk1.4-autotune-udpdiag"
count = text.count(old_version)
if count != 2:
    raise SystemExit(f"v0.36 package version anchor count: {count}")
text = text.replace(old_version, new_version)

repls = [
    ("versionCode=44", "versionCode=49"),
    (
        "description=A52 Turnip Vulkan 1.4 v0.32 sync-merge fix. Retains v0.31 efficiency policy and fixes Mesa 26.2.2 KGSL mixed timestamp/sync-FD merge bugs that caused a release-build null dereference in Warframe.",
        "description=A52 Turnip Vulkan 1.4 v0.36 diagnostic build from the confirmed v0.32 functional baseline. Rendering policy is unchanged. Device creation plus autotune init, entry, early-return and bandwidth decisions are emitted as bounded UDP loopback telemetry on port 39353 and captured by the bundled tg-autotune-rx tool."
    ),
]
for old, new in repls:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"v0.36 package metadata anchor count for {old!r}: {count}")
    text = text.replace(old, new, 1)

rx_var_anchor = 'YV12_PROBE="$BUILD_DIR/dist/turnip-yv12-sample-probe"\n'
if text.count(rx_var_anchor) != 1:
    raise SystemExit(f"v0.36 receiver variable anchor count: {text.count(rx_var_anchor)}")
text = text.replace(rx_var_anchor, rx_var_anchor + 'TG_RX="$BUILD_DIR/dist/tg-autotune-rx"\n', 1)

rx_test_anchor = 'test -s "$YV12_PROBE"\n'
if text.count(rx_test_anchor) != 1:
    raise SystemExit(f"v0.36 receiver test anchor count: {text.count(rx_test_anchor)}")
text = text.replace(rx_test_anchor, rx_test_anchor + 'test -s "$TG_RX"\n', 1)

rx_copy_anchor = 'cp "$YV12_PROBE" "$OUT_DIR/module/tools/turnip-yv12-sample-probe"\n'
if text.count(rx_copy_anchor) != 1:
    raise SystemExit(f"v0.36 receiver copy anchor count: {text.count(rx_copy_anchor)}")
text = text.replace(rx_copy_anchor, rx_copy_anchor + 'cp "$TG_RX" "$OUT_DIR/module/tools/tg-autotune-rx"\n', 1)

rx_perm_anchor = 'set_perm "$MODPATH/tools/turnip-yv12-sample-probe" 0 0 0755\n'
if text.count(rx_perm_anchor) != 1:
    raise SystemExit(f"v0.36 receiver permission anchor count: {text.count(rx_perm_anchor)}")
text = text.replace(rx_perm_anchor, rx_perm_anchor + 'set_perm "$MODPATH/tools/tg-autotune-rx" 0 0 0755\n', 1)

p.write_text(text)
PY

chmod +x "$TMP"
"$TMP" "$ROOT" "$BUILD_DIR" "$OUT_DIR"

OLD="$OUT_DIR/touchGrass-Turnip-A619-Mesa-26.2.2-KGSL-Vulkan-1.4-PERSISTENT-KSU.zip"
NEW="$OUT_DIR/touchGrass-Turnip-A619-Mesa-26.2.2-v0.36-AUTOTUNE-UDP-DIAG-KSU.zip"
[ -s "$OLD" ] || { echo "expected persistent module zip missing: $OLD" >&2; exit 3; }
mv "$OLD" "$NEW"

echo "v036_package=$NEW"
