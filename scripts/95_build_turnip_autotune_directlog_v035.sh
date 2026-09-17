#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
NDK="${2:-${ANDROID_NDK_ROOT:-}}"
OUT="${3:-$ROOT/artifacts/turnip-mesa-26.2.2-v035}"
BASE="$ROOT/scripts/92_build_turnip_mesa_26_2_2.sh"
PATCH="$ROOT/scripts/95_patch_turnip_autotune_directlog.py"
TMP="$ROOT/.tmp-95-build-turnip-autotune-directlog.sh"

[ -f "$BASE" ] || { echo "missing base build script: $BASE" >&2; exit 2; }
[ -f "$PATCH" ] || { echo "missing v0.35 patch script: $PATCH" >&2; exit 2; }
cp "$BASE" "$TMP"
trap 'rm -f "$TMP"' EXIT

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
anchor = 'TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"\n'
if text.count(anchor) != 1:
    raise SystemExit(f"v0.35 injection anchor count: {text.count(anchor)}")

inject = (
    'echo "==> Enable v0.35 direct Android autotune diagnostics"\n'
    'python3 "$ROOT/scripts/95_patch_turnip_autotune_directlog.py" "$SRC"\n\n'
)
text = text.replace(anchor, inject + anchor, 1)

old_meta = 'runtime_logging=errors-warnings-only-no-bringup-success-traces\n'
new_meta = 'runtime_logging=autotune-direct-android-liblog-diagnostic\n'
if text.count(old_meta) != 1:
    raise SystemExit(f"runtime logging metadata anchor count: {text.count(old_meta)}")
text = text.replace(old_meta, new_meta, 1)

mode_anchor = 'kgsl_sync_merge=fixed-mixed-ts-syncfd-and-cross-queue-ts\n'
if text.count(mode_anchor) != 1:
    raise SystemExit(f"BUILD-INFO diagnostic anchor count: {text.count(mode_anchor)}")
text = text.replace(
    mode_anchor,
    mode_anchor + 'autotune_diagnostics=direct-liblog-init-call-decision-bandwidth\n',
    1,
)

p.write_text(text)
PY

chmod +x "$TMP"
exec "$TMP" "$ROOT" "$NDK" "$OUT"
