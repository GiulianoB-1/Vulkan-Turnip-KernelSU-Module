#!/system/bin/sh

DRIVER="${1:-/data/local/tmp/vulkan.adreno.so}"
PROBE="${2:-/data/local/tmp/turnip-vk-probe}"
OUT="${3:-/data/local/tmp/turnip-live-test.txt}"
AHB_PROBE="${4:-/data/local/tmp/turnip-ahb-probe}"
YV12_SAMPLE_PROBE="${5:-/data/local/tmp/turnip-yv12-sample-probe}"
WATCH="${OUT%.txt}-kernel-watch.txt"
YV12_REF="${OUT%.txt}-yv12-stock-ref.txt"
WATCH_PID=""

TARGET=/vendor/lib64/hw/vulkan.adreno.so
STAGE_DIR=/dev/touchgrass-turnip-live
STAGE="$STAGE_DIR/vulkan.adreno.so"

cleanup() {
    if [ -n "$WATCH_PID" ]; then
        kill "$WATCH_PID" 2>/dev/null || true
        wait "$WATCH_PID" 2>/dev/null || true
    fi
    umount "$TARGET" 2>/dev/null || true
    rm -rf "$STAGE_DIR"
}

trap cleanup EXIT HUP INT TERM

exec >"$OUT" 2>&1

echo "========== TURNIP A619 LIVE TEST =========="
date
echo

echo "=== PRECHECK ==="
getprop ro.product.device
getprop ro.product.model
getprop ro.board.platform
getprop ro.build.version.sdk
echo "stock_hal=$TARGET"
ls -lZ "$TARGET" 2>/dev/null || ls -l "$TARGET"
sha256sum "$TARGET" 2>/dev/null || true
echo "driver=$DRIVER"
ls -lZ "$DRIVER" 2>/dev/null || ls -l "$DRIVER"
sha256sum "$DRIVER" 2>/dev/null || true
echo

if [ ! -f "$TARGET" ]; then
    echo "FAIL: stock Vulkan HAL missing"
    exit 10
fi
if [ ! -f "$DRIVER" ]; then
    echo "FAIL: Turnip driver missing"
    exit 11
fi
if [ ! -x "$PROBE" ]; then
    echo "FAIL: Vulkan probe missing/not executable"
    exit 12
fi
if [ ! -x "$AHB_PROBE" ]; then
    echo "FAIL: AHardwareBuffer probe missing/not executable"
    exit 18
fi
if [ ! -x "$YV12_SAMPLE_PROBE" ]; then
    echo "FAIL: YV12 sample probe missing/not executable"
    exit 19
fi

echo "=== STOCK QUALCOMM SUBMISSION BASELINE ==="
"$PROBE"
STOCK_RC=$?
echo "stock_probe_exit=$STOCK_RC"
echo
sync

if [ "$STOCK_RC" -ne 0 ]; then
    echo "FAIL: stock Qualcomm Vulkan failed the same submission probe"
    exit 17
fi

echo "=== STOCK QUALCOMM AHB IMPORT BASELINE ==="
if command -v timeout >/dev/null 2>&1; then
    timeout 45 "$AHB_PROBE"
    STOCK_AHB_RC=$?
else
    "$AHB_PROBE"
    STOCK_AHB_RC=$?
fi
echo "stock_ahb_probe_exit=$STOCK_AHB_RC"
echo
sync

echo "=== STOCK QUALCOMM YV12 GPU SAMPLE BASELINE ==="
if command -v timeout >/dev/null 2>&1; then
    timeout 45 "$YV12_SAMPLE_PROBE" --write-ref "$YV12_REF"
    STOCK_YV12_RC=$?
else
    "$YV12_SAMPLE_PROBE" --write-ref "$YV12_REF"
    STOCK_YV12_RC=$?
fi
echo "stock_yv12_sample_exit=$STOCK_YV12_RC"
echo
sync

if [ "$STOCK_YV12_RC" -ne 0 ]; then
    echo "FAIL: stock Qualcomm failed the YV12 GPU sampling baseline"
    exit 20
fi

mkdir -p "$STAGE_DIR" || exit 13
cp -f "$DRIVER" "$STAGE" || exit 14
chown 0:0 "$STAGE" 2>/dev/null || true
chmod 0644 "$STAGE" || exit 15
chcon u:object_r:vendor_file:s0 "$STAGE" 2>/dev/null || true

echo "=== BIND MOUNT ==="
mount -o bind "$STAGE" "$TARGET" || {
    echo "FAIL: bind mount"
    exit 16
}
cat /proc/mounts | grep -F 'vulkan.adreno.so' || true
sha256sum "$TARGET" 2>/dev/null || true
echo

echo "=== TURNIP VULKAN SUBMISSION PROBE ==="
echo "turnip_probe_begin=1"
echo "kernel_watch=$WATCH"
: > "$WATCH"
{
    echo "========== TURNIP KERNEL WATCH =========="
    date
    echo "=== INITIAL GPU/KGSL STATE ==="
    dmesg | grep -Ei 'kgsl|adreno|gmu|gpu|iommu|smmu' | tail -120
    echo "=== LIVE KERNEL STREAM ==="
} >> "$WATCH" 2>&1
dmesg -w >> "$WATCH" 2>&1 &
WATCH_PID=$!
sync

if command -v timeout >/dev/null 2>&1; then
    timeout 25 "$PROBE"
    PROBE_RC=$?
else
    "$PROBE"
    PROBE_RC=$?
fi
echo "turnip_vk_probe_exit=$PROBE_RC"
echo

echo "=== TURNIP ANDROID HARDWARE BUFFER IMPORT PROBE ==="
if command -v timeout >/dev/null 2>&1; then
    timeout 45 "$AHB_PROBE"
    AHB_PROBE_RC=$?
else
    "$AHB_PROBE"
    AHB_PROBE_RC=$?
fi
echo "turnip_ahb_probe_exit=$AHB_PROBE_RC"
echo

echo "=== TURNIP YV12 POST-FILL IMPORT PROBE ==="
if command -v timeout >/dev/null 2>&1; then
    timeout 45 "$YV12_SAMPLE_PROBE" --compare-ref "$YV12_REF"
    YV12_POSTFILL_RC=$?
else
    "$YV12_SAMPLE_PROBE" --compare-ref "$YV12_REF"
    YV12_POSTFILL_RC=$?
fi
echo "turnip_yv12_postfill_exit=$YV12_POSTFILL_RC"
echo

echo "=== TURNIP YV12 IMPORT-FIRST GPU SAMPLE PROBE ==="
if command -v timeout >/dev/null 2>&1; then
    timeout 45 "$YV12_SAMPLE_PROBE" --import-before-fill --compare-ref "$YV12_REF"
    YV12_IMPORTFIRST_RC=$?
else
    "$YV12_SAMPLE_PROBE" --import-before-fill --compare-ref "$YV12_REF"
    YV12_IMPORTFIRST_RC=$?
fi
echo "turnip_yv12_importfirst_exit=$YV12_IMPORTFIRST_RC"
echo

if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
fi
sync
echo "turnip_probe_exit=$PROBE_RC"
echo "=== TURNIP KERNEL WATCH TAIL ==="
tail -250 "$WATCH" 2>/dev/null || true
echo "probe_exit=$PROBE_RC"
echo "ahb_probe_exit=$AHB_PROBE_RC"
echo "yv12_postfill_exit=$YV12_POSTFILL_RC"
echo "yv12_importfirst_exit=$YV12_IMPORTFIRST_RC"
echo

echo "=== CMD GPU VKJSON ==="
cmd gpu vkjson 2>&1 || true
echo

echo "=== RECENT VULKAN LOGCAT ==="
logcat -d -b all | grep -i -E 'turnip|mesa|vulkan|freedreno|kgsl|adreno' | tail -250
echo

echo "=== GPU/KGSL FAULTS ==="
dmesg | grep -Ei 'kgsl|adreno|gmu|gpu|iommu|smmu' | grep -Ei 'fault|error|timeout|hang|panic|oops|BUG|recover|reset' | tail -200
echo

echo "=== RESULT ==="
if [ "$PROBE_RC" -eq 0 ] && [ "$AHB_PROBE_RC" -eq 0 ] && [ "$YV12_POSTFILL_RC" -eq 0 ] && [ "$YV12_IMPORTFIRST_RC" -eq 0 ]; then
    echo "TURNIP_LIVE_TEST=PASS"
elif [ "$PROBE_RC" -eq 0 ] && [ "$AHB_PROBE_RC" -eq 0 ] && [ "$YV12_IMPORTFIRST_RC" -eq 0 ]; then
    echo "TURNIP_LIVE_TEST=PARTIAL_POSTFILL_IMPORT_FAIL"
else
    echo "TURNIP_LIVE_TEST=FAIL"
fi
echo "========== END =========="

if [ "$PROBE_RC" -ne 0 ]; then
    exit "$PROBE_RC"
fi
if [ "$AHB_PROBE_RC" -ne 0 ]; then
    exit "$AHB_PROBE_RC"
fi
if [ "$YV12_IMPORTFIRST_RC" -ne 0 ]; then
    exit "$YV12_IMPORTFIRST_RC"
fi
exit "$YV12_POSTFILL_RC"
