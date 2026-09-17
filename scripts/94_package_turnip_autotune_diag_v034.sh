#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
BUILD_DIR="${2:-$ROOT/artifacts/turnip-mesa-26.2.2-v034}"
OUT_DIR="${3:-$ROOT/release-turnip-autotune-v034}"
BASE="$ROOT/scripts/92_package_turnip_a619_persistent_module.sh"
TMP="$ROOT/.tmp-94-package-turnip-autotune-diag.sh"

[ -f "$BASE" ] || { echo "missing base package script: $BASE" >&2; exit 2; }
cp "$BASE" "$TMP"
trap 'rm -f "$TMP"' EXIT

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()

# The v0.32 version string exists twice intentionally: once in module.prop and
# once in the base package's final ZIP audit. Both must move together so the
# generated module and its self-audit agree.
old_version = "version=0.32-vk1.4-syncmerge-fix"
new_version = "version=0.34a-vk1.4-autotune-logcat"
version_count = text.count(old_version)
if version_count != 2:
    raise SystemExit(
        f"package version anchor count for {old_version!r}: {version_count}")
text = text.replace(old_version, new_version)

single_repls = [
    ("versionCode=44", "versionCode=47"),
    (
        "description=A52 Turnip Vulkan 1.4 v0.32 sync-merge fix. Retains v0.31 efficiency policy and fixes Mesa 26.2.2 KGSL mixed timestamp/sync-FD merge bugs that caused a release-build null dereference in Warframe.",
        "description=A52 Turnip Vulkan 1.4 v0.34a diagnostic build from the confirmed v0.32 baseline. Functional rendering behavior is unchanged; Mesa autotune diagnostics are promoted to warning-level TGAT logcat markers for GMEM-vs-SYSMEM analysis."
    ),
]
for old, new in single_repls:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"package metadata anchor count for {old!r}: {count}")
    text = text.replace(old, new, 1)

p.write_text(text)
PY

chmod +x "$TMP"
"$TMP" "$ROOT" "$BUILD_DIR" "$OUT_DIR"

OLD="$OUT_DIR/touchGrass-Turnip-A619-Mesa-26.2.2-KGSL-Vulkan-1.4-PERSISTENT-KSU.zip"
NEW="$OUT_DIR/touchGrass-Turnip-A619-Mesa-26.2.2-v0.34a-AUTOTUNE-LOGCAT-DIAG-KSU.zip"
[ -s "$OLD" ] || { echo "expected persistent module zip missing: $OLD" >&2; exit 3; }
mv "$OLD" "$NEW"

echo "v034a_package=$NEW"
