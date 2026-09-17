#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
NDK="${2:-${ANDROID_NDK_ROOT:-}}"
OUT="${3:-$ROOT/artifacts/turnip-mesa-26.2.2-v036}"
BASE="$ROOT/scripts/92_build_turnip_mesa_26_2_2.sh"
PATCH="$ROOT/scripts/96_patch_turnip_autotune_udpdiag.py"
RX_SRC="$ROOT/scripts/96_tg_autotune_udp_rx.c"
TMP="$ROOT/.tmp-96-build-turnip-autotune-udpdiag.sh"

[ -f "$BASE" ] || { echo "missing base build script: $BASE" >&2; exit 2; }
[ -f "$PATCH" ] || { echo "missing v0.36 patch script: $PATCH" >&2; exit 2; }
[ -f "$RX_SRC" ] || { echo "missing v0.36 receiver source: $RX_SRC" >&2; exit 2; }
[ -n "$NDK" ] || { echo "Android NDK root required" >&2; exit 2; }

cp "$BASE" "$TMP"
trap 'rm -f "$TMP"' EXIT

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
anchor = 'TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"\n'
if text.count(anchor) != 1:
    raise SystemExit(f"v0.36 injection anchor count: {text.count(anchor)}")

inject = (
    'echo "==> Enable v0.36 UDP autotune diagnostics"\n'
    'python3 "$ROOT/scripts/96_patch_turnip_autotune_udpdiag.py" "$SRC"\n\n'
)
text = text.replace(anchor, inject + anchor, 1)

old_meta = 'runtime_logging=errors-warnings-only-no-bringup-success-traces\n'
new_meta = 'runtime_logging=autotune-udp-loopback-diagnostic\n'
if text.count(old_meta) != 1:
    raise SystemExit(f"runtime logging metadata anchor count: {text.count(old_meta)}")
text = text.replace(old_meta, new_meta, 1)

mode_anchor = 'kgsl_sync_merge=fixed-mixed-ts-syncfd-and-cross-queue-ts\n'
if text.count(mode_anchor) != 1:
    raise SystemExit(f"BUILD-INFO diagnostic anchor count: {text.count(mode_anchor)}")
text = text.replace(
    mode_anchor,
    mode_anchor + 'autotune_diagnostics=udp-loopback-device-init-call-decision-bandwidth-port39353\n',
    1,
)

p.write_text(text)
PY

chmod +x "$TMP"
"$TMP" "$ROOT" "$NDK" "$OUT"

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CC="$TOOLCHAIN/bin/aarch64-linux-android36-clang"
[ -x "$CC" ] || { echo "missing compiler: $CC" >&2; exit 3; }
mkdir -p "$OUT/dist"
"$CC" -O2 -Wall -Wextra -Werror "$RX_SRC" -o "$OUT/dist/tg-autotune-rx"
chmod 0755 "$OUT/dist/tg-autotune-rx"
file "$OUT/dist/tg-autotune-rx" | grep -Fq 'ARM aarch64'
strings "$OUT/dist/tg-autotune-rx" | grep -Fq 'TGAT_RX_READY'
strings "$OUT/dist/tg-autotune-rx" | grep -Fq 'TGAT_RX_COUNT='

echo "v036_receiver=$OUT/dist/tg-autotune-rx"
