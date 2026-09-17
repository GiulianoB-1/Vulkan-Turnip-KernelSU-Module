#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
NDK="${2:-${ANDROID_NDK_ROOT:-}}"
OUT="${3:-$ROOT/artifacts/turnip-mesa-26.2.2}"

MESA_VERSION="26.2.2"
MESA_SHA256="eeb29ca7e56cfaa8e8a79538dcf834e3b18e501c31bef5145e959ea437cc4216"
MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
ANDROID_API="36"

if [ -z "$NDK" ] || [ ! -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]; then
  echo "invalid Android NDK path: $NDK" >&2
  exit 2
fi

mkdir -p "$OUT"
WORK="$OUT/work"
SRC="$WORK/mesa-${MESA_VERSION}"
BUILD="$WORK/build-aarch64"
DIST="$OUT/dist"
rm -rf "$WORK" "$DIST"
mkdir -p "$WORK" "$DIST"

echo "==> Fetch Mesa ${MESA_VERSION}"
curl -fL --retry 5 --retry-delay 3 "$MESA_URL" -o "$WORK/mesa.tar.xz"
echo "$MESA_SHA256  $WORK/mesa.tar.xz" | sha256sum -c -
tar -C "$WORK" -xf "$WORK/mesa.tar.xz"

echo "==> Verify A619 + KGSL source support"
grep -Fq 'GPUId(619)' "$SRC/src/freedreno/common/freedreno_devices.py"
grep -Fq "freedreno_kmds.contains('kgsl')" "$SRC/src/freedreno/vulkan/meson.build"
grep -Fq "libtu_files += files('tu_knl_kgsl.cc')" "$SRC/src/freedreno/vulkan/meson.build"
grep -Fq 'PUBLIC struct hwvulkan_module_t HAL_MODULE_INFO_SYM' "$SRC/src/vulkan/runtime/vk_android.c"

echo "==> Backport Android YV12 explicit-layout support for Mesa 26.2.2"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])

def replace_once(path, old, new, label):
    p = src / path
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 anchor, found {count}")
    p.write_text(text.replace(old, new, 1))

# Backport the FDL part of Turnip-Enhanced commit
# aeaf924c56adf7eddb0a9033b33474b48367e33d onto Mesa 26.2.2.
# The source commit is based on a newer Mesa tree, so applying the full patch
# directly is intentionally avoided.  These changes are limited to exact
# imported level-0 pitch preservation and the narrowly validated Android YV12
# AHB shape that our SurfaceFlinger probe reproduces.

replace_once(
    "src/freedreno/fdl/freedreno_layout.h",
    """struct fdl_explicit_layout {
   uint32_t offset;
   uint32_t pitch;
};""",
    """struct fdl_explicit_layout {
   uint32_t offset;
   uint32_t pitch;

   /* Optional validation alignment for an imported single-level linear
    * image. Zero keeps the ordinary hardware-layout requirement.
    */
   uint32_t pitch_alignment;

   /* Imported sampled-only Android images do not need Turnip's private
    * four-row tail padding. This is only accepted for a single-level,
    * single-layer, linear, non-UBWC image.
    */
   bool skip_last_level_padding;
};""",
    "fdl_explicit_layout fields",
)

replace_once(
    "src/freedreno/fdl/freedreno_layout.h",
    """   bool ubwc : 1;
   bool layer_first : 1; /* see above description */
   bool tile_all : 1;
   bool is_mutable : 1;
""",
    """   bool ubwc : 1;
   bool layer_first : 1; /* see above description */
   bool tile_all : 1;
   bool is_mutable : 1;
   bool has_explicit_pitch : 1;
""",
    "fdl_layout explicit pitch flag",
)

replace_once(
    "src/freedreno/fdl/freedreno_layout.h",
    """static inline uint32_t
fdl_pitch(const struct fdl_layout *layout, unsigned level)
{
   return align(u_minify(layout->pitch0, level), 1 << layout->pitchalign);
}""",
    """static inline uint32_t
fdl_pitch(const struct fdl_layout *layout, unsigned level)
{
   /* An imported level-0 row pitch is authoritative. pitchalign remains the
    * minimum derived-mip pitch encoded in the descriptor.
    */
   if (level == 0 && layout->has_explicit_pitch)
      return layout->pitch0;

   return align(u_minify(layout->pitch0, level), 1 << layout->pitchalign);
}""",
    "fdl_pitch explicit level0",
)

replace_once(
    "src/freedreno/fdl/fd6_layout.c",
    """   if (explicit_layout) {
      offset = explicit_layout->offset;
      layout->pitch0 = explicit_layout->pitch;
      if (align(layout->pitch0, 1 << layout->pitchalign) != layout->pitch0)
         return false;
   }""",
    """   if (explicit_layout) {
      offset = explicit_layout->offset;
      layout->pitch0 = explicit_layout->pitch;
      layout->has_explicit_pitch = true;

      if (explicit_layout->skip_last_level_padding &&
          (layout->tile_mode != TILE6_LINEAR || layout->ubwc ||
           params->mip_levels != 1 || params->array_size != 1 ||
           params->depth0 != 1 || params->is_3d))
         return false;

      uint32_t pitch_alignment = 1u << layout->pitchalign;
      if (explicit_layout->pitch_alignment) {
         if (layout->tile_mode != TILE6_LINEAR || params->mip_levels != 1 ||
             !util_is_power_of_two_nonzero(explicit_layout->pitch_alignment) ||
             explicit_layout->pitch_alignment < layout->cpp)
            return false;

         pitch_alignment = explicit_layout->pitch_alignment;
      }

      if (align(layout->pitch0, pitch_alignment) != layout->pitch0)
         return false;
   }""",
    "fdl explicit pitch validation",
)

replace_once(
    "src/freedreno/fdl/fd6_layout.c",
    """      if (level == params->mip_levels - 1)
         nblocksy = align(nblocksy, 4);""",
    """      if (level == params->mip_levels - 1 &&
          !(explicit_layout && explicit_layout->skip_last_level_padding))
         nblocksy = align(nblocksy, 4);""",
    "fdl imported tail padding",
)

# Samsung/QCOM's legacy GRALLOC_MODULE_PERFORM_GET_YUV_PLANE_INFO can
# return android_ycbcr pointers as offsets when the buffer is unmapped, but
# as absolute mapped virtual addresses after a CPU lock/unlock. Mesa 26.2.2
# assumes the former unconditionally and truncates those addresses into the
# int offset fields, which makes a previously CPU-touched YV12 import fail.
# Normalize only the exact planar YV12 case, using the Y pointer as the base.
replace_once(
    "src/util/u_gralloc/u_gralloc_internal.c",
    """#include <hardware/gralloc.h>
#include <errno.h>
""",
    """#include <hardware/gralloc.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
""",
    "u_gralloc mapped YV12 includes",
)

replace_once(
    "src/util/u_gralloc/u_gralloc_internal.c",
    """   enum chroma_order chroma_order =
      ((size_t)ycbcr->cr < (size_t)ycbcr->cb) ? YCrCb : YCbCr;

   /* .chroma_step is the byte distance between the same chroma channel
""",
    """   uintptr_t y_ptr = (uintptr_t)ycbcr->y;
   uintptr_t cb_ptr = (uintptr_t)ycbcr->cb;
   uintptr_t cr_ptr = (uintptr_t)ycbcr->cr;

   enum chroma_order chroma_order =
      (cr_ptr < cb_ptr) ? YCrCb : YCbCr;

   /* The legacy QCOM perform API may return offsets from a null base while
    * the allocation is unmapped, then return real process virtual addresses
    * after AHardwareBuffer_lockPlanes()/unlock().  This is reproducible on
    * the A52 YV12 path.  Preserve the ordinary offset mode, but for the exact
    * 3-plane YV12 shape normalize a mapped address triplet back to offsets.
    */
   if (hnd->hal_format == HAL_PIXEL_FORMAT_YV12 &&
       ycbcr->chroma_step == 1 &&
       y_ptr > INT_MAX && cb_ptr >= y_ptr && cr_ptr >= y_ptr) {
      cb_ptr -= y_ptr;
      cr_ptr -= y_ptr;
      y_ptr = 0;

      if (cb_ptr > INT_MAX || cr_ptr > INT_MAX) {
         mesa_logw("YV12 mapped plane offsets exceed Mesa import range");
         return -EINVAL;
      }

      mesa_logi("touchGrass: normalized mapped QCOM YV12 android_ycbcr pointers");
   }

   /* .chroma_step is the byte distance between the same chroma channel
""",
    "u_gralloc mapped YV12 normalize",
)

replace_once(
    "src/util/u_gralloc/u_gralloc_internal.c",
    """   out->offsets[0] = (size_t)ycbcr->y;
   /* We assume here that all the planes are located in one DMA-buf. */
   if (chroma_order == YCrCb) {
      out->offsets[1] = (size_t)ycbcr->cr;
      out->offsets[2] = (size_t)ycbcr->cb;
   } else {
      out->offsets[1] = (size_t)ycbcr->cb;
      out->offsets[2] = (size_t)ycbcr->cr;
   }
""",
    """   out->offsets[0] = (int)y_ptr;
   /* We assume here that all the planes are located in one DMA-buf. */
   if (chroma_order == YCrCb) {
      out->offsets[1] = (int)cr_ptr;
      out->offsets[2] = (int)cb_ptr;
   } else {
      out->offsets[1] = (int)cb_ptr;
      out->offsets[2] = (int)cr_ptr;
   }
""",
    "u_gralloc normalized YV12 offsets",
)



# v0.26: support Qualcomm/Samsung flexible YUV_420_888 allocations that
# resolve to semiplanar CrCb (NV21).  The A52 gralloc returns private format
# 0x113 (NV21_ZSL) for AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420, but the public
# android_ycbcr description is sufficient: Y plane + interleaved CrCb plane,
# chroma_step=2.  Mesa 26.2.2 only has the YCbCr/NV12 table entry, so its
# generic legacy-qcom gralloc path rejects the otherwise valid allocation.
#
# Preserve the physical NV21 ordering all the way through Vulkan by using a
# Mesa-private opaque Android externalFormat token.  Images resolve the token
# to VK_FORMAT_G8_B8R8_2PLANE_420_UNORM for storage/layout, while the common
# YCbCr conversion state records an R/B swap so Turnip samples CrCb correctly.
replace_once(
    "src/util/u_gralloc/u_gralloc_internal.c",
    """   {HAL_PIXEL_FORMAT_YCbCr_420_888, YCbCr, 2, DRM_FORMAT_NV12},
   {HAL_PIXEL_FORMAT_YCbCr_420_888, YCbCr, 1, DRM_FORMAT_YUV420},
""",
    """   {HAL_PIXEL_FORMAT_YCbCr_420_888, YCbCr, 2, DRM_FORMAT_NV12},
   {HAL_PIXEL_FORMAT_YCbCr_420_888, YCrCb, 2, DRM_FORMAT_NV21},
   {HAL_PIXEL_FORMAT_YCrCb_420_SP, YCrCb, 2, DRM_FORMAT_NV21},
   {HAL_PIXEL_FORMAT_YCbCr_420_888, YCbCr, 1, DRM_FORMAT_YUV420},
""",
    "flexible YUV420 NV21 fourcc",
)

replace_once(
    "src/util/u_gralloc/u_gralloc_internal.c",
    """   if (hnd->hal_format == HAL_PIXEL_FORMAT_YV12 &&
       ycbcr->chroma_step == 1 &&
       y_ptr > INT_MAX && cb_ptr >= y_ptr && cr_ptr >= y_ptr) {
      cb_ptr -= y_ptr;
      cr_ptr -= y_ptr;
      y_ptr = 0;

      if (cb_ptr > INT_MAX || cr_ptr > INT_MAX) {
         mesa_logw("YV12 mapped plane offsets exceed Mesa import range");
         return -EINVAL;
      }

      mesa_logi("touchGrass: normalized mapped QCOM YV12 android_ycbcr pointers");
   }
""",
    """   const bool mapped_yv12 =
      hnd->hal_format == HAL_PIXEL_FORMAT_YV12 &&
      ycbcr->chroma_step == 1;
   const bool mapped_flexible_420 =
      hnd->hal_format == HAL_PIXEL_FORMAT_YCbCr_420_888 &&
      ycbcr->chroma_step == 2;
   const bool mapped_explicit_nv21 =
      hnd->hal_format == HAL_PIXEL_FORMAT_YCrCb_420_SP &&
      ycbcr->chroma_step == 2;

   if ((mapped_yv12 || mapped_flexible_420 || mapped_explicit_nv21) &&
       y_ptr > INT_MAX && cb_ptr >= y_ptr && cr_ptr >= y_ptr) {
      cb_ptr -= y_ptr;
      cr_ptr -= y_ptr;
      y_ptr = 0;

      if (cb_ptr > INT_MAX || cr_ptr > INT_MAX) {
         mesa_logw("mapped QCOM YUV plane offsets exceed Mesa import range");
         return -EINVAL;
      }

      if (mapped_yv12)
         mesa_logi("touchGrass: normalized mapped QCOM YV12 android_ycbcr pointers");
      else if (mapped_explicit_nv21)
         mesa_logi("touchGrass: normalized mapped QCOM explicit NV21 android_ycbcr pointers");
      else
         mesa_logi("touchGrass: normalized mapped QCOM flexible YUV420 android_ycbcr pointers");
   }
""",
    "mapped flexible YUV420 pointer normalization",
)

replace_once(
    "src/vulkan/runtime/vk_android.h",
    """struct u_gralloc;
struct vk_device;
struct vk_image;
""",
    """/* Mesa's Android runtime historically uses VkFormat values directly as
 * externalFormat tokens.  NV12 and NV21 share the same Vulkan storage format,
 * so use one private opaque token to preserve the physical CrCb distinction.
 */
#define VK_ANDROID_EXTERNAL_FORMAT_TOUCHGRASS_NV21 0x4d4553414e563231ull

static inline bool
vk_android_external_format_is_touchgrass_nv21(uint64_t external_format)
{
   return external_format == VK_ANDROID_EXTERNAL_FORMAT_TOUCHGRASS_NV21;
}

static inline VkFormat
vk_android_external_format_to_vk_format(uint64_t external_format)
{
   if (vk_android_external_format_is_touchgrass_nv21(external_format))
      return VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;

   return (VkFormat) external_format;
}

struct u_gralloc;
struct vk_device;
struct vk_image;
""",
    "Android NV21 external-format token",
)

replace_once(
    "src/vulkan/runtime/vk_android.c",
    """   VkFormat external_format = p->format;
""",
    """   uint64_t external_format = p->format;
   VkFormat resolved_external_format = p->format;
""",
    "AHB external/resolved format split",
)

replace_once(
    "src/vulkan/runtime/vk_android.c",
    """   switch (info.drm_fourcc) {
   case DRM_FORMAT_YVU420:
      /* Assuming that U and V planes are swapped earlier */
      external_format = VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM;
      break;
   case DRM_FORMAT_NV12:
      external_format = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
      break;
   case DRM_FORMAT_P010:
      external_format = VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
      break;
   case DRM_FORMAT_XBGR8888:
      /* This can be resolved from IMPLEMENTATION_DEFINED AHB format */
      external_format = VK_FORMAT_R8G8B8A8_UNORM;
      break;
   default:
      mesa_loge("Unsupported external DRM format: %d", info.drm_fourcc);
      return VK_ERROR_INVALID_EXTERNAL_HANDLE;
   }
""",
    """   switch (info.drm_fourcc) {
   case DRM_FORMAT_YVU420:
      /* Assuming that U and V planes are swapped earlier */
      resolved_external_format = VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM;
      external_format = resolved_external_format;
      break;
   case DRM_FORMAT_NV12:
      resolved_external_format = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
      external_format = resolved_external_format;
      break;
   case DRM_FORMAT_NV21:
      resolved_external_format = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
      external_format = VK_ANDROID_EXTERNAL_FORMAT_TOUCHGRASS_NV21;
      mesa_logi("touchGrass: resolved flexible Android YUV420 CrCb as NV21");
      break;
   case DRM_FORMAT_P010:
      resolved_external_format =
         VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
      external_format = resolved_external_format;
      break;
   case DRM_FORMAT_XBGR8888:
      /* This can be resolved from IMPLEMENTATION_DEFINED AHB format */
      resolved_external_format = VK_FORMAT_R8G8B8A8_UNORM;
      external_format = resolved_external_format;
      break;
   default:
      mesa_loge("Unsupported external DRM format: %d", info.drm_fourcc);
      return VK_ERROR_INVALID_EXTERNAL_HANDLE;
   }
""",
    "AHB NV21 external-format resolution",
)

replace_once(
    "src/vulkan/runtime/vk_android.c",
    """   device->physical->dispatch_table.GetPhysicalDeviceFormatProperties2(
      (VkPhysicalDevice)device->physical, external_format, &format_properties);

   p->formatFeatures = format_properties.formatProperties.optimalTilingFeatures;
   p->externalFormat = external_format;
""",
    """   device->physical->dispatch_table.GetPhysicalDeviceFormatProperties2(
      (VkPhysicalDevice)device->physical, resolved_external_format,
      &format_properties);

   p->formatFeatures = format_properties.formatProperties.optimalTilingFeatures;
   p->externalFormat = external_format;
""",
    "AHB resolved-format feature query",
)

replace_once(
    "src/vulkan/runtime/vk_android.c",
    """         const uint32_t num_bits = vk_format_get_component_bits(
            format_prop2->externalFormat, UTIL_FORMAT_COLORSPACE_RGB, 1);
""",
    """         const VkFormat resolved_format =
            vk_android_external_format_to_vk_format(
               format_prop2->externalFormat);
         const uint32_t num_bits = vk_format_get_component_bits(
            resolved_format, UTIL_FORMAT_COLORSPACE_RGB, 1);
""",
    "AHB external-format resolve bits",
)

replace_once(
    "src/vulkan/runtime/vk_image.c",
    """      vk_image_set_format(image, (VkFormat)ext_format->externalFormat);
""",
    """      vk_image_set_format(
         image,
         vk_android_external_format_to_vk_format(ext_format->externalFormat));
""",
    "vk_image NV21 external-format resolution",
)

replace_once(
    "src/vulkan/runtime/vk_ycbcr_conversion.c",
    """#include "vk_ycbcr_conversion.h"

#include <vulkan/vulkan_android.h>
""",
    """#include "vk_ycbcr_conversion.h"

#include "vk_android.h"

#include <vulkan/vulkan_android.h>
""",
    "YCbCr Android external-format helper include",
)

replace_once(
    "src/vulkan/runtime/vk_ycbcr_conversion.c",
    """   /* We assume that Android externalFormat is just a VkFormat */
   if (android_ext_info && android_ext_info->externalFormat) {
      assert(pCreateInfo->format == VK_FORMAT_UNDEFINED);
      state->format = android_ext_info->externalFormat;
   } else {
""",
    """   /* Most Mesa Android externalFormat values are VkFormat values.  Keep
    * that behavior, but resolve the private NV21 token and install the
    * component swap required for physical CrCb (NV21) storage.
    */
   if (android_ext_info && android_ext_info->externalFormat) {
      assert(pCreateInfo->format == VK_FORMAT_UNDEFINED);
      state->format =
         vk_android_external_format_to_vk_format(
            android_ext_info->externalFormat);

      if (vk_android_external_format_is_touchgrass_nv21(
             android_ext_info->externalFormat)) {
         state->mapping[0] = VK_COMPONENT_SWIZZLE_B;
         state->mapping[1] = VK_COMPONENT_SWIZZLE_IDENTITY;
         state->mapping[2] = VK_COMPONENT_SWIZZLE_R;
         state->mapping[3] = VK_COMPONENT_SWIZZLE_IDENTITY;
      } else {
         state->mapping[0] = VK_COMPONENT_SWIZZLE_IDENTITY;
         state->mapping[1] = VK_COMPONENT_SWIZZLE_IDENTITY;
         state->mapping[2] = VK_COMPONENT_SWIZZLE_IDENTITY;
         state->mapping[3] = VK_COMPONENT_SWIZZLE_IDENTITY;
      }
   } else {
""",
    "YCbCr NV21 external-format component mapping",
)


# v0.17: import QTI's private NV12 Venus UBWC Android buffers
# (HAL format 0x7fa30c06) through the legacy Qualcomm PlaneLayoutInfo ABI.
#
# The v0.16 SurfaceFlinger tombstone proved the remaining failure is no longer
# the exact-size RGB/CCU path.  SurfaceFlinger aborts while importing a
# 720x1280 AHardwareBuffer whose vendor format is 0x7fa30c06.  Mesa 26.2.2's
# old qcom gralloc backend does not classify that private format as YUV and
# consequently returns VK_ERROR_INVALID_EXTERNAL_HANDLE.
#
# Keep this deliberately narrow.  We runtime-load the exact public Qualcomm
# GetYUVPlaneInfo(BufferInfo, ...) symbol, validate the native-handle ABI and
# all four physical NV12-UBWC ranges (Y data, UV data, Y metadata, UV
# metadata), cross-check the handle-aware android_ycbcr result returned by the
# already-active gralloc module, then normalize it to the two logical Vulkan
# planes expected by DRM_FORMAT_NV12 + DRM_FORMAT_MOD_QCOM_COMPRESSED.
replace_once(
    "src/util/u_gralloc/u_gralloc_qcom.c",
    """#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
""",
    """#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
""",
    "qcom NV12 UBWC includes",
)

replace_once(
    "src/util/u_gralloc/u_gralloc_qcom.c",
    """/* Using this gralloc is not recommended for new distributions. */

struct qcom_gralloc {
""",
    r"""/* Using this gralloc is not recommended for new distributions. */

#define TG_QTI_NV12_UBWC_FORMAT 0x7fa30c06
#define TG_QTI_TP10_UBWC_FORMAT 0x7fa30c09
#define TG_QTI_HANDLE_NUM_FDS 2
#define TG_QTI_HANDLE_MIN_INTS 22
#define TG_QTI_HANDLE_MAX_INTS 26
#define TG_QTI_HANDLE_MAGIC \
   (('g' << 24) | ('m' << 16) | ('s' << 8) | 'm')

#define TG_QTI_HANDLE_FLAGS_INDEX 3
#define TG_QTI_HANDLE_WIDTH_INDEX 4
#define TG_QTI_HANDLE_HEIGHT_INDEX 5
#define TG_QTI_HANDLE_UNALIGNED_WIDTH_INDEX 6
#define TG_QTI_HANDLE_UNALIGNED_HEIGHT_INDEX 7
#define TG_QTI_HANDLE_FORMAT_INDEX 8
#define TG_QTI_HANDLE_LAYER_COUNT_INDEX 10
#define TG_QTI_HANDLE_USAGE_INDEX 13
#define TG_QTI_HANDLE_SIZE_INDEX 15
#define TG_QTI_HANDLE_OFFSET_INDEX 16
#define TG_QTI_HANDLE_BASE_INDEX 18

#define TG_QTI_FLAG_SECURE_BUFFER 0x00000400u
#define TG_QTI_FLAG_UBWC_ALIGNED 0x08000000u
#define TG_QTI_FLAG_UBWC_ALIGNED_PI 0x40000000u

#define TG_QTI_PLANE_Y (1u << 0)
#define TG_QTI_PLANE_CB (1u << 1)
#define TG_QTI_PLANE_CR (1u << 2)
#define TG_QTI_PLANE_META (1u << 31)

#define TG_QTI_GET_YUV_PLANE_LAYOUTS_SYMBOL \
   "_ZN7gralloc15GetYUVPlaneInfoERKNS_10BufferInfoEiiiiPiPNS_15PlaneLayoutInfoE"

struct tg_qti_buffer_info {
   int32_t width;
   int32_t height;
   int32_t format;
   int32_t layer_count;
   uint64_t usage;
};

struct tg_qti_plane_layout_info {
   uint32_t component;
   uint32_t horizontal_subsampling;
   uint32_t vertical_subsampling;
   uint32_t offset;
   int32_t step;
   int32_t stride;
   int32_t stride_bytes;
   int32_t scanlines;
   uint32_t size;
};

typedef int (*tg_qti_get_yuv_plane_layouts_t)(
   const struct tg_qti_buffer_info *info, int32_t format, int32_t width,
   int32_t height, int32_t flags, int *plane_count,
   struct tg_qti_plane_layout_info *plane_info);

struct qcom_gralloc {
""",
    "qcom NV12 UBWC ABI definitions",
)

replace_once(
    "src/util/u_gralloc/u_gralloc_qcom.c",
    """   void *perform_handle;
   int (* perform)(void *dev, int op, ...);
   struct u_gralloc *fallback_gralloc;
};
""",
    """   void *perform_handle;
   int (* perform)(void *dev, int op, ...);
   struct u_gralloc *fallback_gralloc;
   void *grallocutils;
   tg_qti_get_yuv_plane_layouts_t get_yuv_plane_layouts;
};
""",
    "qcom NV12 UBWC runtime helper fields",
)

qcom = src / "src/util/u_gralloc/u_gralloc_qcom.c"
qcom_text = qcom.read_text()
qcom_helper_anchor = """static int
fallback_gralloc_get_yuv_info(struct u_gralloc *gralloc,
"""
if qcom_text.count(qcom_helper_anchor) != 1:
    raise SystemExit(
        f"qcom NV12 UBWC helper anchor count: {qcom_text.count(qcom_helper_anchor)}"
    )

qcom_helpers = r"""static uint64_t
tg_qti_read_u64(const native_handle_t *handle, int index)
{
   uint64_t value = 0;
   memcpy(&value, &handle->data[index], sizeof(value));
   return value;
}

static bool
tg_qti_pointer_matches(uintptr_t base, uint32_t offset, const void *pointer)
{
   const uintptr_t value = (uintptr_t) pointer;

   /* Legacy Samsung/QCOM gralloc can return either null-based offsets or
    * base-relative process virtual addresses depending on mapping state.
    */
   if (value == (uintptr_t) offset)
      return true;

   return offset <= UINTPTR_MAX - base && value == base + offset;
}

static bool
tg_qti_plane_range_valid(const struct tg_qti_plane_layout_info *plane,
                         uint32_t component, uint32_t hsub, uint32_t vsub,
                         int32_t step, int32_t aligned_width,
                         uint64_t declared_size, uint64_t dma_size)
{
   if (plane->component != component ||
       plane->horizontal_subsampling != hsub ||
       plane->vertical_subsampling != vsub ||
       (step >= 0 && plane->step != step) ||
       plane->stride != aligned_width ||
       plane->stride_bytes <= 0 || plane->scanlines <= 0 ||
       plane->size == 0 || plane->offset > INT_MAX)
      return false;

   const uint64_t offset = plane->offset;
   const uint64_t size = plane->size;
   const uint64_t stride = (uint64_t) plane->stride_bytes;
   const uint64_t rows = (uint64_t) plane->scanlines;

   if (offset > declared_size || size > declared_size - offset ||
       offset > dma_size || size > dma_size - offset ||
       rows > UINT64_MAX / stride || stride * rows > size)
      return false;

   return true;
}

/* Return -EAGAIN when the handle is not one of the private QTI UBWC
 * allocations we own. Once a supported private format is positively
 * identified, every inconsistency is a hard failure so it can never fall
 * through and be guessed as linear.
 */
static int
tg_qcom_get_qti_ubwc_info(struct qcom_gralloc *gr,
                           struct u_gralloc_buffer_handle *hnd,
                           struct u_gralloc_buffer_basic_info *out)
{
   if (!hnd || !hnd->handle || !gr->get_yuv_plane_layouts)
      return -EAGAIN;

   const native_handle_t *handle = hnd->handle;
   if (sizeof(void *) != 8 ||
       handle->version != sizeof(native_handle_t) ||
       handle->numFds != TG_QTI_HANDLE_NUM_FDS ||
       handle->numInts < TG_QTI_HANDLE_MIN_INTS ||
       handle->numInts > TG_QTI_HANDLE_MAX_INTS ||
       handle->data[handle->numFds] != TG_QTI_HANDLE_MAGIC)
      return -EAGAIN;

   const int32_t private_format = handle->data[TG_QTI_HANDLE_FORMAT_INDEX];
   const bool is_nv12_ubwc = private_format == TG_QTI_NV12_UBWC_FORMAT;
   const bool is_tp10_ubwc = private_format == TG_QTI_TP10_UBWC_FORMAT;
   if (!is_nv12_ubwc && !is_tp10_ubwc)
      return -EAGAIN;

   if (hnd->hal_format != TG_QTI_NV12_UBWC_FORMAT &&
       hnd->hal_format != TG_QTI_TP10_UBWC_FORMAT &&
       hnd->hal_format != HAL_PIXEL_FORMAT_IMPLEMENTATION_DEFINED &&
       hnd->hal_format != HAL_PIXEL_FORMAT_YCbCr_420_888) {
      if (is_tp10_ubwc)
         mesa_loge("touchGrass TP10 reject=hal_format hal=0x%x", hnd->hal_format);
      return -EINVAL;
   }

   /* Qualcomm TP10 UBWC is packed 10-bit 4:2:0. Its UV plane advances
    * three bytes per chroma pair. Some vendor PlaneLayoutInfo revisions do
    * not initialize the Y-plane step for TP10, so do not use that field as
    * a validity gate for TP10. All byte strides, offsets, sizes and the
    * handle-aware android_ycbcr view are still independently validated.
    */
   const int expected_y_step = is_tp10_ubwc ? -1 : 1;
   const int expected_uv_step = is_tp10_ubwc ? 3 : 2;

   const uint32_t flags =
      (uint32_t) handle->data[TG_QTI_HANDLE_FLAGS_INDEX];
   const int32_t width = handle->data[TG_QTI_HANDLE_WIDTH_INDEX];
   const int32_t height = handle->data[TG_QTI_HANDLE_HEIGHT_INDEX];
   const int32_t unaligned_width =
      handle->data[TG_QTI_HANDLE_UNALIGNED_WIDTH_INDEX];
   const int32_t unaligned_height =
      handle->data[TG_QTI_HANDLE_UNALIGNED_HEIGHT_INDEX];
   const int32_t layer_count =
      handle->data[TG_QTI_HANDLE_LAYER_COUNT_INDEX];
   const uint64_t usage =
      tg_qti_read_u64(handle, TG_QTI_HANDLE_USAGE_INDEX);
   const int32_t declared_size_i =
      handle->data[TG_QTI_HANDLE_SIZE_INDEX];
   const uintptr_t base =
      (uintptr_t) tg_qti_read_u64(handle, TG_QTI_HANDLE_BASE_INDEX);

   if (is_tp10_ubwc)
      mesa_loge("touchGrass TP10 handle flags=0x%x aligned=%dx%d unaligned=%dx%d layers=%d size=%d usage=0x%llx",
                flags, width, height, unaligned_width, unaligned_height,
                layer_count, declared_size_i, (unsigned long long) usage);

   if (width <= 0 || height <= 0 ||
       unaligned_width <= 0 || unaligned_height <= 0 ||
       width < unaligned_width || height < unaligned_height ||
       layer_count != 1 || declared_size_i <= 0 ||
       handle->data[TG_QTI_HANDLE_OFFSET_INDEX] != 0 ||
       !(flags & TG_QTI_FLAG_UBWC_ALIGNED) ||
       (flags & (TG_QTI_FLAG_UBWC_ALIGNED_PI |
                 TG_QTI_FLAG_SECURE_BUFFER))) {
      if (is_tp10_ubwc)
         mesa_loge("touchGrass TP10 reject=handle_validation offset=%d",
                   handle->data[TG_QTI_HANDLE_OFFSET_INDEX]);
      return -EINVAL;
   }

   const uint64_t declared_size = (uint32_t) declared_size_i;
   off_t dma_end = lseek(handle->data[0], 0, SEEK_END);
   if (is_tp10_ubwc)
      mesa_loge("touchGrass TP10 dma declared=%llu actual=%lld",
                (unsigned long long) declared_size, (long long) dma_end);
   if (dma_end <= 0 || declared_size > (uint64_t) dma_end) {
      if (is_tp10_ubwc)
         mesa_loge("touchGrass TP10 reject=dma_size");
      return -EINVAL;
   }
   const uint64_t dma_size = (uint64_t) dma_end;

   struct tg_qti_buffer_info info = {
      .width = unaligned_width,
      .height = unaligned_height,
      .format = private_format,
      .layer_count = 1,
      .usage = usage,
   };
   struct tg_qti_plane_layout_info planes[8];
   memset(planes, 0, sizeof(planes));
   int plane_count = 0;

   int ret = gr->get_yuv_plane_layouts(
      &info, private_format, width, height, 0, &plane_count, planes);
   if (is_tp10_ubwc) {
      mesa_loge("touchGrass TP10 GetYUVPlaneInfo ret=%d count=%d", ret, plane_count);
      if (ret == 0 && plane_count >= 0 && plane_count <= 8) {
         for (int i = 0; i < plane_count; ++i) {
            mesa_loge("touchGrass TP10 plane[%d] comp=0x%x sub=%u,%u off=%u step=%d stride=%d bytes=%d scan=%d size=%u",
                      i, planes[i].component,
                      planes[i].horizontal_subsampling,
                      planes[i].vertical_subsampling,
                      planes[i].offset, planes[i].step,
                      planes[i].stride, planes[i].stride_bytes,
                      planes[i].scanlines, planes[i].size);
         }
      }
   }
   if (ret != 0 || plane_count != 4) {
      if (is_tp10_ubwc)
         mesa_loge("touchGrass TP10 reject=plane_query");
      return -EINVAL;
   }

   const struct tg_qti_plane_layout_info *y = &planes[0];
   const struct tg_qti_plane_layout_info *uv = &planes[1];
   const struct tg_qti_plane_layout_info *y_meta = &planes[2];
   const struct tg_qti_plane_layout_info *uv_meta = &planes[3];

   const bool y_valid = tg_qti_plane_range_valid(
      y, TG_QTI_PLANE_Y, 0, 0, expected_y_step, width,
      declared_size, dma_size);
   const bool uv_valid = tg_qti_plane_range_valid(
      uv, TG_QTI_PLANE_CB | TG_QTI_PLANE_CR, 1, 1,
      expected_uv_step, width, declared_size, dma_size);
   const bool y_meta_valid = tg_qti_plane_range_valid(
      y_meta, TG_QTI_PLANE_META | TG_QTI_PLANE_Y, 0, 0, 0, width,
      declared_size, dma_size);
   const bool uv_meta_valid = tg_qti_plane_range_valid(
      uv_meta, TG_QTI_PLANE_META | TG_QTI_PLANE_CB | TG_QTI_PLANE_CR,
      0, 0, 0, width, declared_size, dma_size);
   if (is_tp10_ubwc)
      mesa_loge("touchGrass TP10 plane_valid y=%d uv=%d ym=%d uvm=%d",
                y_valid, uv_valid, y_meta_valid, uv_meta_valid);
   if (!y_valid || !uv_valid || !y_meta_valid || !uv_meta_valid) {
      if (is_tp10_ubwc)
         mesa_loge("touchGrass TP10 reject=plane_validation");
      return -EINVAL;
   }

   const uint64_t y_meta_end =
      (uint64_t) y_meta->offset + y_meta->size;
   const uint64_t y_end = (uint64_t) y->offset + y->size;
   const uint64_t uv_meta_end =
      (uint64_t) uv_meta->offset + uv_meta->size;
   const uint64_t uv_end = (uint64_t) uv->offset + uv->size;

   /* Progressive QTI NV12 UBWC is physically:
    * Y metadata -> Y data -> UV metadata -> UV data.
    */
   if (is_tp10_ubwc)
      mesa_loge("touchGrass TP10 ordering ym=%u y=%u uvm=%u uv=%u ends=%llu,%llu,%llu,%llu",
                y_meta->offset, y->offset, uv_meta->offset, uv->offset,
                (unsigned long long) y_meta_end,
                (unsigned long long) y_end,
                (unsigned long long) uv_meta_end,
                (unsigned long long) uv_end);
   if (y_meta->offset != 0 ||
       (uint64_t) y->offset != y_meta_end ||
       (uint64_t) uv_meta->offset != y_end ||
       (uint64_t) uv->offset != uv_meta_end ||
       uv_end > declared_size || uv_end > dma_size) {
      if (is_tp10_ubwc)
         mesa_loge("touchGrass TP10 reject=plane_order");
      return -EINVAL;
   }

   /* Independently cross-check the layout against the handle-aware vendor
    * query used by the stock gralloc module.
    */
   struct android_ycbcr ycbcr[2];
   memset(ycbcr, 0, sizeof(ycbcr));
   ret = gr->perform(gr->perform_handle,
                     GRALLOC_MODULE_PERFORM_GET_YUV_PLANE_INFO,
                     handle, ycbcr);
   if (is_tp10_ubwc)
      mesa_loge("touchGrass TP10 ycbcr ret=%d y=%p cb=%p cr=%p ys=%zu cs=%zu step=%zu base=0x%llx",
                ret, ycbcr[0].y, ycbcr[0].cb, ycbcr[0].cr,
                ycbcr[0].ystride, ycbcr[0].cstride,
                ycbcr[0].chroma_step, (unsigned long long) base);
   if (ret != 0 ||
       ycbcr[1].y || ycbcr[1].cb || ycbcr[1].cr ||
       ycbcr[1].ystride || ycbcr[1].cstride ||
       ycbcr[1].chroma_step ||
       ycbcr[0].ystride != (size_t) y->stride_bytes ||
       ycbcr[0].cstride != (size_t) uv->stride_bytes ||
       ycbcr[0].chroma_step != (size_t) expected_uv_step ||
       !tg_qti_pointer_matches(base, y->offset, ycbcr[0].y) ||
       !tg_qti_pointer_matches(base, uv->offset, ycbcr[0].cb) ||
       uv->offset == UINT32_MAX ||
       !tg_qti_pointer_matches(base, uv->offset + 1, ycbcr[0].cr)) {
      if (is_tp10_ubwc)
         mesa_loge("touchGrass TP10 reject=ycbcr_crosscheck");
      return -EINVAL;
   }

   out->drm_fourcc = is_tp10_ubwc ? DRM_FORMAT_NV15 : DRM_FORMAT_NV12;
   out->modifier = DRM_FORMAT_MOD_QCOM_COMPRESSED;
   out->num_planes = 2;
   out->fds[0] = out->fds[1] = handle->data[0];

   /* For QCOM_COMPRESSED, Turnip's logical plane starts at the metadata
    * range. FDL computes the primary-data offset from the modifier geometry.
    */
   out->offsets[0] = (int) y_meta->offset;
   out->offsets[1] = (int) uv_meta->offset;
   out->strides[0] = y->stride_bytes;
   out->strides[1] = uv->stride_bytes;

   if (is_tp10_ubwc)
      mesa_logi("touchGrass: imported QTI TP10 UBWC 0x7fa30c09 as NV15 via legacy PlaneLayoutInfo");
   else
      mesa_logi("touchGrass: imported QTI NV12 UBWC 0x7fa30c06 via legacy PlaneLayoutInfo");
   return 0;
}

"""
qcom_text = qcom_text.replace(
    qcom_helper_anchor, qcom_helpers + qcom_helper_anchor, 1
)

get_info_anchor = """   int out_flag = 0;
   int err;

   err = gr->perform(gr->perform_handle, GRALLOC_MODULE_PERFORM_GET_UBWC_FLAG,
"""
get_info_new = """   int out_flag = 0;
   int err;

   /* Intercept only positively identified private QTI NV12/TP10 UBWC
    * handles. -EAGAIN means this is an ordinary allocation and the Mesa
    * 26.2.2 path below remains untouched.
    */
   int qti_ret = tg_qcom_get_qti_ubwc_info(gr, hnd, out);
   if (qti_ret != -EAGAIN)
      return qti_ret;

   err = gr->perform(gr->perform_handle, GRALLOC_MODULE_PERFORM_GET_UBWC_FLAG,
"""
if qcom_text.count(get_info_anchor) != 1:
    raise SystemExit(
        f"qcom NV12 UBWC get_buffer_info anchor count: {qcom_text.count(get_info_anchor)}"
    )
qcom_text = qcom_text.replace(get_info_anchor, get_info_new, 1)

destroy_anchor = """   if (gr->fallback_gralloc)
      gr->fallback_gralloc->ops.destroy(gr->fallback_gralloc);

   FREE(gr);
"""
destroy_new = """   if (gr->fallback_gralloc)
      gr->fallback_gralloc->ops.destroy(gr->fallback_gralloc);

   if (gr->grallocutils)
      dlclose(gr->grallocutils);

   FREE(gr);
"""
if qcom_text.count(destroy_anchor) != 1:
    raise SystemExit(
        f"qcom NV12 UBWC destroy anchor count: {qcom_text.count(destroy_anchor)}"
    )
qcom_text = qcom_text.replace(destroy_anchor, destroy_new, 1)

create_anchor = """   if (out_stride == 0)
      goto fail;

   gr->base.ops.get_buffer_basic_info = get_buffer_info;
"""
create_new = r"""   if (out_stride == 0)
      goto fail;

   /* Prefer the helper already loaded with the active gralloc module.  If the
    * dependency is not in that lookup scope, try the process-wide scope and
    * finally take an explicit reference.  Failure is non-fatal for ordinary
    * buffers; only the supported private QTI UBWC imports require this
    * helper.
    */
   void *plane_symbol =
      dlsym(gr->gralloc_module->dso, TG_QTI_GET_YUV_PLANE_LAYOUTS_SYMBOL);
   if (!plane_symbol)
      plane_symbol = dlsym(RTLD_DEFAULT, TG_QTI_GET_YUV_PLANE_LAYOUTS_SYMBOL);
   if (!plane_symbol) {
      gr->grallocutils = dlopen("libgrallocutils.so", RTLD_NOW | RTLD_LOCAL);
      if (gr->grallocutils)
         plane_symbol =
            dlsym(gr->grallocutils, TG_QTI_GET_YUV_PLANE_LAYOUTS_SYMBOL);
   }

   if (plane_symbol) {
      memcpy(&gr->get_yuv_plane_layouts, &plane_symbol,
             sizeof(gr->get_yuv_plane_layouts));
      mesa_logi("touchGrass: QTI legacy PlaneLayoutInfo helper available");
   }

   gr->base.ops.get_buffer_basic_info = get_buffer_info;
"""
if qcom_text.count(create_anchor) != 1:
    raise SystemExit(
        f"qcom NV12 UBWC create anchor count: {qcom_text.count(create_anchor)}"
    )
qcom_text = qcom_text.replace(create_anchor, create_new, 1)

qcom.write_text(qcom_text)

# Trace the generic Android AHB resolution layer directly to stderr for the
# two private QTI UBWC formats. Android log routing is device/build dependent,
# while stderr from the standalone probe is deterministic.
replace_once(
    "src/vulkan/runtime/vk_android.c",
    """#include <unistd.h>
""",
    """#include <stdio.h>
#include <unistd.h>
""",
    "vk_android QTI AHB trace stdio",
)

replace_once(
    "src/vulkan/runtime/vk_android.c",
    """   struct u_gralloc_buffer_basic_info info;
   if (u_gralloc_get_buffer_basic_info(vk_android_get_ugralloc(), &gr_handle,
                                       &info) != 0) {
      mesa_loge("Failed to get u_gralloc_buffer_basic_info");
      return VK_ERROR_INVALID_EXTERNAL_HANDLE;
   }

   switch (info.drm_fourcc) {
""",
    """   struct u_gralloc_buffer_basic_info info;
   memset(&info, 0, sizeof(info));
   int tg_basic_ret =
      u_gralloc_get_buffer_basic_info(vk_android_get_ugralloc(), &gr_handle,
                                      &info);

   const bool tg_qti_private =
      desc.format == 0x7fa30c06u || desc.format == 0x7fa30c09u;
   if (tg_qti_private) {
      fprintf(stderr,
              "touchGrass AHB basic hal=0x%08x ret=%d fourcc=0x%08x modifier=0x%016llx planes=%d\\n",
              desc.format, tg_basic_ret, info.drm_fourcc,
              (unsigned long long) info.modifier, info.num_planes);
      if (tg_basic_ret == 0) {
         for (int i = 0; i < info.num_planes && i < 4; ++i) {
            fprintf(stderr,
                    "touchGrass AHB plane[%d] fd=%d off=%d stride=%d\\n",
                    i, info.fds[i], info.offsets[i], info.strides[i]);
         }
      }
      fflush(stderr);
   }

   if (tg_basic_ret != 0) {
      mesa_loge("Failed to get u_gralloc_buffer_basic_info");
      return VK_ERROR_INVALID_EXTERNAL_HANDLE;
   }

   switch (info.drm_fourcc) {
""",
    "vk_android QTI AHB basic-info stderr trace",
)

tu = src / "src/freedreno/vulkan/tu_image.cc"
text = tu.read_text()
anchor = """template <chip CHIP>
VkResult
tu_image_init(struct tu_device *device, struct tu_image *image,
              const VkImageCreateInfo *pCreateInfo, uint64_t modifier,
              const VkSubresourceLayout *plane_layouts)
{"""
if text.count(anchor) != 1:
    raise SystemExit(f"tu_image_init anchor count: {text.count(anchor)}")

helper = r"""static bool
tu_is_android_yv12_import(struct tu_image *image, uint64_t modifier,
                          const VkSubresourceLayout *plane_layouts)
{
   const bool is_android_buffer =
      vk_image_is_android_hardware_buffer(&image->vk) ||
      vk_image_is_android_native_buffer(&image->vk) ||
      vk_image_is_android_native_buffer_alias(&image->vk);

   if (!plane_layouts || modifier != DRM_FORMAT_MOD_LINEAR ||
       !is_android_buffer ||
       image->vk.format != VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM ||
       image->vk.image_type != VK_IMAGE_TYPE_2D ||
       image->vk.samples != VK_SAMPLE_COUNT_1_BIT ||
       image->vk.mip_levels != 1 || image->vk.array_layers != 1 ||
       image->vk.extent.depth != 1 ||
       image->vk.usage != VK_IMAGE_USAGE_SAMPLED_BIT ||
       (image->vk.extent.width & 1) || (image->vk.extent.height & 1))
      return false;

   const uint64_t y_pitch = plane_layouts[0].rowPitch;
   const uint64_t cb_pitch = plane_layouts[1].rowPitch;
   const uint64_t cr_pitch = plane_layouts[2].rowPitch;

   if (!y_pitch || !cb_pitch || y_pitch > UINT32_MAX ||
       cb_pitch > UINT32_MAX || cr_pitch != cb_pitch ||
       y_pitch < image->vk.extent.width ||
       cb_pitch < image->vk.extent.width / 2 ||
       (y_pitch & 15) ||
       cb_pitch != ((y_pitch / 2 + 15) & ~UINT64_C(15)))
      return false;

   const uint64_t height = image->vk.extent.height;
   if (height > UINT64_MAX / y_pitch ||
       height / 2 > UINT64_MAX / cb_pitch)
      return false;

   const uint64_t y_size = y_pitch * height;
   const uint64_t chroma_size = cb_pitch * (height / 2);
   if (y_size > UINT32_MAX ||
       chroma_size > (UINT32_MAX - y_size) / 2)
      return false;

   /* vk_android already converts DRM Y-V-U order into Vulkan Y-U-V order. */
   return plane_layouts[0].offset == 0 &&
          plane_layouts[2].offset == y_size &&
          plane_layouts[1].offset == y_size + chroma_size;
}

"""
text = text.replace(anchor, helper + anchor, 1)

anchor2 = """   assert(!(image->vk.create_flags & VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT) ||
          tile_mode == TILE6_3);

   for (uint32_t i = 0; i < tu6_plane_count(image->vk.format); i++) {"""
new2 = """   assert(!(image->vk.create_flags & VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT) ||
          tile_mode == TILE6_3);

   /* Android YV12 guarantees 16-byte row-pitch alignment. Only relax the
    * imported-layout validation for the exact sampled-only linear AHB shape.
    */
   const bool android_yv12_import =
      tu_is_android_yv12_import(image, modifier, plane_layouts);

   for (uint32_t i = 0; i < tu6_plane_count(image->vk.format); i++) {"""
if text.count(anchor2) != 1:
    raise SystemExit(f"YV12 insertion anchor count: {text.count(anchor2)}")
text = text.replace(anchor2, new2, 1)

anchor3 = """      struct fdl_explicit_layout plane_layout;

      if (plane_layouts) {"""
new3 = """      struct fdl_explicit_layout plane_layout = {
         .pitch_alignment = android_yv12_import ? 16u : 0u,
         .skip_last_level_padding = android_yv12_import,
      };

      if (plane_layouts) {"""
if text.count(anchor3) != 1:
    raise SystemExit(f"plane layout init anchor count: {text.count(anchor3)}")
text = text.replace(anchor3, new3, 1)

# Backport Turnip-Enhanced 76a4087d9e26fd2470936fae698827b6a2872528.
# Android gralloc linear color allocations can end exactly at the final
# logical row. Turnip's ordinary last-level tail padding plus event/CCU GMEM
# fast paths may then access beyond the dma-buf and produce CCU write
# translation faults. Preserve the exact imported footprint and route edge
# loads/stores through bounded paths.
replace_once(
    "src/freedreno/vulkan/tu_image.h",
    """   struct fdl_layout layout[3];
   uint64_t subsampled_metadata_offset;
   uint64_t total_size;

   /* Set when bound */
""",
    """   struct fdl_layout layout[3];
   uint64_t subsampled_metadata_offset;
   uint64_t total_size;

   /* Exact-size linear Android imports have no private FDL tail rows, so
    * mem<->GMEM operations must use bounded edge paths when necessary.
    */
   bool android_external_no_gmem_padding;

   /* Set when bound */
""",
    "tu_image exact linear Android flag",
)

helper_anchor = """template <chip CHIP>
VkResult
tu_image_init(struct tu_device *device, struct tu_image *image,
              const VkImageCreateInfo *pCreateInfo, uint64_t modifier,
              const VkSubresourceLayout *plane_layouts)
{"""
if text.count(helper_anchor) != 1:
    raise SystemExit(f"exact-linear helper anchor count: {text.count(helper_anchor)}")

exact_linear_helper = r"""static bool
tu_is_android_exact_linear_color_import(struct tu_image *image,
                                        uint64_t modifier,
                                        const VkSubresourceLayout *plane_layouts)
{
   const VkImageUsageFlags supported_usage =
      VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
      VK_IMAGE_USAGE_TRANSFER_DST_BIT |
      VK_IMAGE_USAGE_SAMPLED_BIT |
      VK_IMAGE_USAGE_STORAGE_BIT |
      VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
      VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT |
      VK_IMAGE_USAGE_ATTACHMENT_FEEDBACK_LOOP_BIT_EXT;

   const bool is_android_buffer =
      vk_image_is_android_hardware_buffer(&image->vk) ||
      vk_image_is_android_native_buffer(&image->vk) ||
      vk_image_is_android_native_buffer_alias(&image->vk);

   if (!is_android_buffer || !plane_layouts ||
       modifier != DRM_FORMAT_MOD_LINEAR ||
       tu6_plane_count(image->vk.format) != 1 ||
       !vk_format_is_color(image->vk.format) ||
       vk_format_is_depth_or_stencil(image->vk.format) ||
       vk_format_is_compressed(image->vk.format) ||
       image->vk.image_type != VK_IMAGE_TYPE_2D ||
       image->vk.samples != VK_SAMPLE_COUNT_1_BIT ||
       image->vk.mip_levels != 1 || image->vk.array_layers != 1 ||
       image->vk.extent.depth != 1 ||
       (image->vk.usage & ~supported_usage))
      return false;

   const enum pipe_format format = tu6_plane_format(image->vk.format, 0);
   if (format == PIPE_FORMAT_NONE)
      return false;

   const uint64_t pitch = plane_layouts[0].rowPitch;
   const uint64_t offset = plane_layouts[0].offset;
   const uint64_t min_pitch =
      util_format_get_stride(format, image->vk.extent.width);
   const uint64_t size = pitch * image->vk.extent.height;

   return pitch >= min_pitch && pitch <= UINT32_MAX &&
          offset <= UINT32_MAX && size <= UINT32_MAX &&
          offset + size <= UINT32_MAX;
}

"""
text = text.replace(helper_anchor, exact_linear_helper + helper_anchor, 1)

layout_anchor = """   /* Layout computation begins here */
   enum a6xx_tile_mode tile_mode = TILE6_3;
#if DETECT_OS_LINUX || DETECT_OS_BSD
"""
layout_new = """   /* Layout computation begins here */
   enum a6xx_tile_mode tile_mode = TILE6_3;
   image->android_external_no_gmem_padding = false;
#if DETECT_OS_LINUX || DETECT_OS_BSD
"""
if text.count(layout_anchor) != 1:
    raise SystemExit(f"exact-linear layout anchor count: {text.count(layout_anchor)}")
text = text.replace(layout_anchor, layout_new, 1)

yv12_bool_anchor = """   const bool android_yv12_import =
      tu_is_android_yv12_import(image, modifier, plane_layouts);

   for (uint32_t i = 0; i < tu6_plane_count(image->vk.format); i++) {"""
yv12_bool_new = """   const bool android_yv12_import =
      tu_is_android_yv12_import(image, modifier, plane_layouts);
   const bool android_exact_linear_color_import =
      tu_is_android_exact_linear_color_import(image, modifier, plane_layouts);
   image->android_external_no_gmem_padding =
      android_exact_linear_color_import;

   for (uint32_t i = 0; i < tu6_plane_count(image->vk.format); i++) {"""
if text.count(yv12_bool_anchor) != 1:
    raise SystemExit(f"exact-linear boolean anchor count: {text.count(yv12_bool_anchor)}")
text = text.replace(yv12_bool_anchor, yv12_bool_new, 1)

plane_padding_anchor = """.skip_last_level_padding = android_yv12_import,"""
plane_padding_new = """.skip_last_level_padding =
            android_yv12_import || android_exact_linear_color_import,"""
if text.count(plane_padding_anchor) != 1:
    raise SystemExit(f"exact-linear padding anchor count: {text.count(plane_padding_anchor)}")
text = text.replace(plane_padding_anchor, plane_padding_new, 1)

bind_anchor = """   assert(mem);
   image->mem = mem;
"""
bind_new = """   assert(mem);

   const bool is_android_buffer =
      vk_image_is_android_hardware_buffer(&image->vk) ||
      vk_image_is_android_native_buffer(&image->vk) ||
      vk_image_is_android_native_buffer_alias(&image->vk);
   if (is_android_buffer && mem->bo &&
       (offset > mem->bo->size ||
        image->total_size > mem->bo->size - offset)) {
      return vk_errorf(device, VK_ERROR_INVALID_EXTERNAL_HANDLE,
                       "Android image binding exceeds dma-buf size (%" PRIu64
                       " + %" PRIu64 " > %" PRIu64 ")",
                       offset, image->total_size, mem->bo->size);
   }

   image->mem = mem;
"""
if text.count(bind_anchor) != 1:
    raise SystemExit(f"exact-linear bind anchor count: {text.count(bind_anchor)}")
text = text.replace(bind_anchor, bind_new, 1)

tu.write_text(text)

clear = src / "src/freedreno/vulkan/tu_clear_blit.cc"
clear_text = clear.read_text()

clear_helper_anchor = """template <chip CHIP>
void
tu_load_gmem_attachment(struct tu_cmd_buffer *cmd,
"""
if clear_text.count(clear_helper_anchor) != 1:
    raise SystemExit(f"bounded GMEM helper anchor count: {clear_text.count(clear_helper_anchor)}")

clear_helper = r"""static bool
tu_attachment_gmem_edge_unaligned(struct tu_cmd_buffer *cmd, uint32_t a,
                                  bool require_image_edge_y_alignment)
{
   struct tu_physical_device *phys_dev = cmd->device->physical_device;
   const struct tu_image_view *iview = cmd->state.attachments[a];

   unsigned render_area_count =
      cmd->state.per_layer_render_area ? cmd->state.pass->num_views : 1;

   /* Existing FDM paths already use bounded coordinates. */
   if (cmd->state.fdm_subsampled)
      return false;

   for (unsigned i = 0; i < render_area_count; i++) {
      const VkRect2D *render_area = &cmd->state.render_areas[i];
      uint32_t x1 = render_area->offset.x;
      uint32_t y1 = render_area->offset.y;
      uint32_t x2 = x1 + render_area->extent.width;
      uint32_t y2 = y1 + render_area->extent.height;

      bool need_x2_align = x2 != iview->view.width;
      if (!need_x2_align &&
          iview->image->android_external_no_gmem_padding) {
         const struct fdl_layout *layout = &iview->image->layout[0];
         const uint64_t aligned_width =
            DIV_ROUND_UP((uint64_t)x2, phys_dev->info->gmem_align_w) *
            phys_dev->info->gmem_align_w;
         const uint64_t required_pitch = aligned_width * layout->cpp;
         need_x2_align = required_pitch > layout->pitch0;
      }

      const bool need_y2_align =
         y2 != iview->view.height || iview->view.need_y2_align ||
         require_image_edge_y_alignment;

      if (x1 % phys_dev->info->gmem_align_w ||
          (x2 % phys_dev->info->gmem_align_w && need_x2_align) ||
          y1 % phys_dev->info->gmem_align_h ||
          (y2 % phys_dev->info->gmem_align_h && need_y2_align))
         return true;
   }

   return false;
}

"""
clear_text = clear_text.replace(clear_helper_anchor,
                                clear_helper + clear_helper_anchor, 1)

load_anchor = """   if (!load_common && !load_stencil)
      return;

   trace_start_gmem_load(&cmd->rp_trace, cs, cmd, attachment->format, force_load);
"""
load_new = """   if (!load_common && !load_stencil)
      return;

   const bool bounded_external_load =
      iview->image->android_external_no_gmem_padding &&
      tu_attachment_gmem_edge_unaligned(cmd, a, true);

   trace_start_gmem_load(&cmd->rp_trace, cs, cmd, attachment->format, force_load);
"""
if clear_text.count(load_anchor) != 1:
    raise SystemExit(f"bounded load anchor count: {clear_text.count(load_anchor)}")
clear_text = clear_text.replace(load_anchor, load_new, 1)

fast_load_anchor = """   if (TU_DEBUG(3D_LOAD) ||
       cmd->state.pass->has_fdm ||
"""
fast_load_new = """   if (TU_DEBUG(3D_LOAD) ||
       bounded_external_load ||
       cmd->state.pass->has_fdm ||
"""
if clear_text.count(fast_load_anchor) != 1:
    raise SystemExit(f"bounded load-path anchor count: {clear_text.count(fast_load_anchor)}")
clear_text = clear_text.replace(fast_load_anchor, fast_load_new, 1)

store_start = clear_text.index("""static bool
tu_attachment_store_unaligned(struct tu_cmd_buffer *cmd, uint32_t a)
{""")
store_end = clear_text.index("""
}

/* The fast path cannot handle mismatched mutability. */""", store_start) + 2
old_store = clear_text[store_start:store_end]
new_store = r"""static bool
tu_attachment_store_unaligned(struct tu_cmd_buffer *cmd, uint32_t a)
{
   const struct tu_image_view *iview = cmd->state.attachments[a];

   /* Unaligned store is incredibly rare in CTS, we have to force it to test. */
   if (TU_DEBUG(UNALIGNED_STORE))
      return true;

   return tu_attachment_gmem_edge_unaligned(
      cmd, a, iview->image->android_external_no_gmem_padding);
}"""
clear_text = clear_text[:store_start] + new_store + clear_text[store_end:]

clear.write_text(clear_text)

# Native Qualcomm TP10 UBWC support for the A52.
#
# Android's private 0x7fa30c09 allocation is exposed by the validated QCOM
# gralloc path as DRM_FORMAT_NV15 + DRM_FORMAT_MOD_QCOM_COMPRESSED.  NV15 is
# tightly packed 10-bit 4:2:0 and must not be interpreted as P010 storage.
#
# Vulkan's standard 10-bit 2-plane format is used only for YCbCr semantics.
# Turnip then marks this private external-format image and overrides its
# storage/view path to native A6xx FMT6_TP10 with Qualcomm's actual UBWC
# metadata geometry: Y 48x4, UV 24x4.
replace_once(
    "src/vulkan/runtime/vk_android.c",
    """   case DRM_FORMAT_P010:
      resolved_external_format =
         VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
      external_format = resolved_external_format;
      break;
   case DRM_FORMAT_XBGR8888:
""",
    """   case DRM_FORMAT_P010:
      resolved_external_format =
         VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
      external_format = resolved_external_format;
      break;
   case DRM_FORMAT_NV15:
      /* Qualcomm TP10 UBWC.  This is tightly packed 10-bit storage, not
       * Vulkan P010.  The standard 10-bit two-plane VkFormat is carried only
       * as the Android external-format YCbCr semantic token; Turnip's A52
       * path programs native A6xx FMT6_TP10 storage/view descriptors.
       */
      resolved_external_format =
         VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
      external_format = resolved_external_format;
      break;
   case DRM_FORMAT_XBGR8888:
""",
    "vk_android NV15 external semantic format",
)

replace_once(
    "src/vulkan/runtime/vk_android.c",
    """finish:

   device->physical->dispatch_table.GetPhysicalDeviceFormatProperties2(
      (VkPhysicalDevice)device->physical, resolved_external_format,
      &format_properties);
""",
    """finish:

   /* Freedreno does not advertise ordinary P010 storage on this A6xx path,
    * but the private TP10 image uses the same Vulkan YCbCr sampling
    * capabilities as NV12.  Query NV12 only for the external-format feature
    * mask; the image/view storage is handled by the native TP10 path.
    */
   VkFormat properties_format = resolved_external_format;
   if (p->format == VK_FORMAT_UNDEFINED &&
       resolved_external_format ==
          VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16)
      properties_format = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;

   device->physical->dispatch_table.GetPhysicalDeviceFormatProperties2(
      (VkPhysicalDevice)device->physical, properties_format, &format_properties);
""",
    "vk_android NV15 feature proxy",
)

# Mark the exact private external-format image in Turnip.  Standard AHB P010
# uses Android's equivalence-table path (pCreateInfo->format is not
# UNDEFINED), so this only matches the private TP10 external-format route.
replace_once(
    "src/freedreno/vulkan/tu_image.h",
    """   bool android_external_no_gmem_padding;

   /* Set when bound */
""",
    """   bool android_external_no_gmem_padding;

   /* Private Qualcomm HAL_PIXEL_FORMAT_YCbCr_420_TP10_UBWC imported through
    * Android external-format semantics.  Storage is native A6xx TP10, not
    * Vulkan P010.
    */
   bool touchgrass_tp10_ubwc;

   /* Set when bound */
""",
    "tu_image TP10 flag",
)

# Carry a per-plane TP10 marker through fdl_image_params.  fdl6_layout_image()
# memset()s the destination layout, so setting the layout marker before that
# call would be lost.
replace_once(
    "src/freedreno/fdl/freedreno_layout.h",
    """   bool force_disable_linear_fallback;

   uint32_t plane;
};""",
    """   bool force_disable_linear_fallback;

   uint32_t plane;

   /* 0 = ordinary layout, 1 = TP10 Y, 2 = TP10 UV. */
   uint8_t touchgrass_tp10_plane;
};""",
    "FDL TP10 params marker",
)

replace_once(
    "src/freedreno/fdl/freedreno_layout.h",
    """   bool is_mutable : 1;
   bool has_explicit_pitch : 1;

   /* Note that for tiled textures""",
    """   bool is_mutable : 1;
   bool has_explicit_pitch : 1;

   /* 0 = ordinary layout, 1 = TP10 Y, 2 = TP10 UV. */
   uint8_t touchgrass_tp10_plane;

   /* Note that for tiled textures""",
    "FDL TP10 layout marker",
)

replace_once(
    "src/freedreno/fdl/fd6_layout.c",
    """   /* special case for r8g8 and plane 1 of r8_g8b8_420_unorm (NV12) */
""",
    """   /* Qualcomm TP10 UBWC metadata covers 48x4 luma samples per Y
    * metadata block and 24x4 chroma sample-pairs per UV metadata block.
    * These values reproduce the vendor Venus allocation byte-for-byte.
    */
   if (layout->touchgrass_tp10_plane == 1) {
      *blockwidth = 48;
      *blockheight = 4;
      return;
   }
   if (layout->touchgrass_tp10_plane == 2) {
      *blockwidth = 24;
      *blockheight = 4;
      return;
   }

   /* special case for r8g8 and plane 1 of r8_g8b8_420_unorm (NV12) */
""",
    "FDL TP10 UBWC geometry",
)

replace_once(
    "src/freedreno/fdl/fd6_layout.c",
    """   layout->tile_mode = params->tile_mode;
   layout->plane = params->plane;
   uint32_t sparse_blocksize = 65536;
""",
    """   layout->tile_mode = params->tile_mode;
   layout->plane = params->plane;
   layout->touchgrass_tp10_plane = params->touchgrass_tp10_plane;
   uint32_t sparse_blocksize = 65536;
""",
    "FDL TP10 marker propagation",
)

replace_once(
    "src/freedreno/fdl/fd6_format_table.c",
    """   _T_(R8_G8B8_420_UNORM, R8_G8B8_2PLANE_420_UNORM, WZYX), /* Gallium NV12 */
   _T_(G8_B8R8_420_UNORM, R8_G8B8_2PLANE_420_UNORM, WZYX), /* Vulkan NV12 */
   _T_(G8_B8_R8_420_UNORM, R8_G8_B8_3PLANE_420_UNORM, WZYX),
""",
    """   _T_(R8_G8B8_420_UNORM, R8_G8B8_2PLANE_420_UNORM, WZYX), /* Gallium NV12 */
   _T_(G8_B8R8_420_UNORM, R8_G8B8_2PLANE_420_UNORM, WZYX), /* Vulkan NV12 */
   _T_(G8_B8_R8_420_UNORM, R8_G8_B8_3PLANE_420_UNORM, WZYX),
   _T_(R10_G10B10_420_UNORM, TP10, WZYX), /* QCOM tightly-packed 10-bit 420 */
""",
    "A6xx native TP10 texture format",
)

replace_once(
    "src/freedreno/fdl/fd6_view.cc",
    """      if (layout->tile_all)
         view->descriptor[3] |= A6XX_TEX_MEMOBJ_3_TILE_ALL;

      if (args->format == PIPE_FORMAT_R8_G8B8_420_UNORM ||
          args->format == PIPE_FORMAT_G8_B8R8_420_UNORM ||
          args->format == PIPE_FORMAT_G8_B8_R8_420_UNORM) {
""",
    """      if (layout->tile_all)
         view->descriptor[3] |= A6XX_TEX_MEMOBJ_3_TILE_ALL;

      if (args->format == PIPE_FORMAT_R8_G8B8_420_UNORM ||
          args->format == PIPE_FORMAT_G8_B8R8_420_UNORM ||
          args->format == PIPE_FORMAT_G8_B8_R8_420_UNORM ||
          args->format == PIPE_FORMAT_R10_G10B10_420_UNORM) {
""",
    "FDL TP10 A6xx multi-plane view",
)

# Native TP10 uses 4 pixels in 5 bytes, so allow this one marked
# NPOT-block format through A6xx UBWC FDL and give it the vendor's 256-byte
# pitch alignment.
replace_once(
    "src/freedreno/fdl/fd6_layout.c",
    """static void
fdl6_tile_alignment(struct fdl_layout *layout, uint32_t *heightalign)
{
   layout->pitchalign = fdl_cpp_shift(layout);
""",
    """static void
fdl6_tile_alignment(struct fdl_layout *layout, uint32_t *heightalign)
{
   if (layout->touchgrass_tp10_plane) {
      layout->cpp_shift = 2;
      layout->pitchalign = 2; /* fdl_set_pitchalign() later adds 6 => 256B */
      *heightalign = 16;
      layout->base_align = 4096;
      return;
   }

   layout->pitchalign = fdl_cpp_shift(layout);
""",
    "FDL TP10 tile alignment",
)

replace_once(
    "src/freedreno/fdl/fd6_layout.c",
    """   if (!util_is_power_of_two_or_zero(layout->cpp)) {
      /* R8G8B8 and other 3 component formats don't get UBWC: */
      ubwc_blockwidth = ubwc_blockheight = 0;
      layout->ubwc = false;
   } else {
""",
    """   if (layout->touchgrass_tp10_plane) {
      /* A6xx has native TP10 UBWC even though cpp is the NPOT 5-byte
       * packed block size. Sparse residency is not used by this AHB path.
       */
      fdl6_get_ubwc_blockwidth(layout, &ubwc_blockwidth, &ubwc_blockheight);
      sparse_blockwidth = sparse_blockheight = 1;
   } else if (!util_is_power_of_two_or_zero(layout->cpp)) {
      /* R8G8B8 and other 3 component formats don't get UBWC: */
      ubwc_blockwidth = ubwc_blockheight = 0;
      layout->ubwc = false;
   } else {
""",
    "FDL TP10 NPOT UBWC",
)

# The Vulkan external-format token is P010-like only for YCbCr semantics.
# FDL must lay out both storage planes with Mesa's native packed TP10 pipe
# format so the explicit 1536-byte vendor pitch and 5-byte/4-pixel packing
# are interpreted correctly.
replace_once(
    "src/freedreno/vulkan/tu_image.cc",
    """      struct fdl_layout *layout = &image->layout[i];
      enum pipe_format format = tu6_plane_format(image->vk.format, i);
      uint32_t width0 = vk_format_get_plane_width(image->vk.format, i, image->vk.extent.width);
""",
    """      struct fdl_layout *layout = &image->layout[i];
      enum pipe_format format =
         image->touchgrass_tp10_ubwc
            ? PIPE_FORMAT_R10_G10B10_420_UNORM
            : tu6_plane_format(image->vk.format, i);
      uint32_t width0 = vk_format_get_plane_width(image->vk.format, i, image->vk.extent.width);
""",
    "TP10 native FDL pipe format",
)

# Turnip image/view integration.
tu = src / "src/freedreno/vulkan/tu_image.cc"
text = tu.read_text()

create_flag_anchor = """   if (!image)
      return vk_error(device, VK_ERROR_OUT_OF_HOST_MEMORY);

   if (vk_image_is_android_native_buffer_alias(&image->vk) ||
       vk_image_is_android_hardware_buffer(&image->vk)) {
"""
create_flag_new = """   if (!image)
      return vk_error(device, VK_ERROR_OUT_OF_HOST_MEMORY);

   const VkExternalFormatANDROID *tg_external_format =
      vk_find_struct_const(pCreateInfo->pNext, EXTERNAL_FORMAT_ANDROID);
   image->touchgrass_tp10_ubwc =
      pCreateInfo->format == VK_FORMAT_UNDEFINED &&
      tg_external_format && tg_external_format->externalFormat ==
         VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 &&
      (image->vk.external_handle_types &
       VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID);

   if (vk_image_is_android_native_buffer_alias(&image->vk) ||
       vk_image_is_android_hardware_buffer(&image->vk)) {
"""
if text.count(create_flag_anchor) != 1:
    raise SystemExit(
        f"TP10 CreateImage flag anchor count: {text.count(create_flag_anchor)}"
    )
text = text.replace(create_flag_anchor, create_flag_new, 1)

init_anchor = """   if (TU_DEBUG(NOUBWC)) {
      ubwc_enabled = false;
   }

   /* Layout computation begins here */
"""
init_new = """   if (TU_DEBUG(NOUBWC)) {
      ubwc_enabled = false;
   }

   if (image->touchgrass_tp10_ubwc) {
      /* The v0.17 SurfaceFlinger failure was a read-only sampled 2D TP10
       * external texture. Keep this support deliberately narrow until it is
       * validated on-device.
       */
      if (pCreateInfo->imageType != VK_IMAGE_TYPE_2D ||
          pCreateInfo->samples != VK_SAMPLE_COUNT_1_BIT ||
          pCreateInfo->mipLevels != 1 ||
          pCreateInfo->arrayLayers != 1 ||
          pCreateInfo->extent.depth != 1 ||
          pCreateInfo->usage != VK_IMAGE_USAGE_SAMPLED_BIT)
         return vk_error(device, VK_ERROR_FORMAT_NOT_SUPPORTED);

      force_linear_tile = false;
      ubwc_enabled = true;
      is_mutable = false;
   }

   /* Layout computation begins here */
"""
if text.count(init_anchor) != 1:
    raise SystemExit(f"TP10 image-init anchor count: {text.count(init_anchor)}")
text = text.replace(init_anchor, init_new, 1)

layout_validate_anchor = """   /* Android YV12 guarantees 16-byte row-pitch alignment. Only relax the
    * imported-layout validation for the exact sampled-only linear AHB shape.
    */
   const bool android_yv12_import =
"""
layout_validate_new = """   if (image->touchgrass_tp10_ubwc) {
      if (!plane_layouts || modifier != DRM_FORMAT_MOD_QCOM_COMPRESSED ||
          tu6_plane_count(image->vk.format) != 2 ||
          plane_layouts[0].offset != 0 ||
          plane_layouts[0].rowPitch == 0 ||
          plane_layouts[1].rowPitch != plane_layouts[0].rowPitch)
         return vk_error(
            device, VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT);

      const uint64_t width = image->vk.extent.width;
      const uint64_t height = image->vk.extent.height;
      const uint64_t pitch = plane_layouts[0].rowPitch;
      const uint64_t y_meta_pitch = ALIGN_POT(DIV_ROUND_UP(width, 48), 64);
      const uint64_t y_meta_rows = ALIGN_POT(DIV_ROUND_UP(height, 4), 16);
      const uint64_t y_meta_size =
         ALIGN_POT(y_meta_pitch * y_meta_rows, 4096);
      const uint64_t y_rows = ALIGN_POT(height, 16);
      const uint64_t expected_uv_meta = y_meta_size + pitch * y_rows;

      if (expected_uv_meta > UINT32_MAX ||
          plane_layouts[1].offset != expected_uv_meta)
         return vk_error(
            device, VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT);

      mesa_logi("touchGrass: validated native TP10 UBWC layout pitch=%" PRIu64
                " uv_meta=%" PRIu64, pitch, expected_uv_meta);
   }

   /* Android YV12 guarantees 16-byte row-pitch alignment. Only relax the
    * imported-layout validation for the exact sampled-only linear AHB shape.
    */
   const bool android_yv12_import =
"""
if text.count(layout_validate_anchor) != 1:
    raise SystemExit(
        f"TP10 layout validation anchor count: {text.count(layout_validate_anchor)}"
    )
text = text.replace(layout_validate_anchor, layout_validate_new, 1)

params_anchor = """         .force_disable_linear_fallback = force_disable_linear_fallback,
         .plane = i,
      };
"""
params_new = """         .force_disable_linear_fallback = force_disable_linear_fallback,
         .plane = i,
         .touchgrass_tp10_plane =
            image->touchgrass_tp10_ubwc ? (uint8_t)(i + 1) : 0,
      };
"""
if text.count(params_anchor) != 1:
    raise SystemExit(
        f"TP10 FDL params anchor count: {text.count(params_anchor)}"
    )
text = text.replace(params_anchor, params_new, 1)

view_format_anchor = """   enum pipe_format format;
   if (iview->vk.format == VK_FORMAT_D32_SFLOAT_S8_UINT)
      format = tu_aspects_to_plane(iview->vk.format, aspect_mask);
   else
      format = vk_format_to_pipe_format(iview->vk.format);
"""
view_format_new = """   enum pipe_format format;
   if (image->touchgrass_tp10_ubwc &&
       aspect_mask == VK_IMAGE_ASPECT_COLOR_BIT)
      format = PIPE_FORMAT_R10_G10B10_420_UNORM;
   else if (iview->vk.format == VK_FORMAT_D32_SFLOAT_S8_UINT)
      format = tu_aspects_to_plane(iview->vk.format, aspect_mask);
   else
      format = vk_format_to_pipe_format(iview->vk.format);
"""
if text.count(view_format_anchor) != 1:
    raise SystemExit(
        f"TP10 image-view format anchor count: {text.count(view_format_anchor)}"
    )
text = text.replace(view_format_anchor, view_format_new, 1)

tu.write_text(text)

# Native TP10 source audits.
native_tp10_checks = [
    ("src/vulkan/runtime/vk_android.c", "case DRM_FORMAT_NV15:", "Android NV15 acceptance"),
    ("src/vulkan/runtime/vk_android.c", "VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16", "TP10 semantic VkFormat"),
    ("src/freedreno/vulkan/tu_image.h", "touchgrass_tp10_ubwc", "Turnip TP10 image marker"),
    ("src/freedreno/fdl/freedreno_layout.h", "touchgrass_tp10_plane", "FDL TP10 plane marker"),
    ("src/freedreno/fdl/fd6_layout.c", "*blockwidth = 48;", "TP10 Y metadata geometry"),
    ("src/freedreno/fdl/fd6_layout.c", "*blockwidth = 24;", "TP10 UV metadata geometry"),
    ("src/freedreno/fdl/fd6_layout.c", "if (layout->touchgrass_tp10_plane) {", "TP10 NPOT UBWC path"),
    ("src/freedreno/vulkan/tu_image.cc", "PIPE_FORMAT_R10_G10B10_420_UNORM", "TP10 native FDL pipe format"),
    ("src/freedreno/fdl/fd6_format_table.c", "_T_(R10_G10B10_420_UNORM, TP10, WZYX)", "native FMT6_TP10 mapping"),
    ("src/freedreno/fdl/fd6_view.cc", "PIPE_FORMAT_R10_G10B10_420_UNORM", "TP10 multi-plane descriptor"),
    ("src/freedreno/vulkan/tu_image.cc", "validated native TP10 UBWC layout", "TP10 exact-layout validation"),
]
for rel, needle, label in native_tp10_checks:
    if needle not in (src / rel).read_text():
        raise SystemExit(f"native TP10 source audit failed: {label}: {needle}")
    print(f"source_audit={label}:PASS")

# Keep patch verification inside Python so an audit failure always names the
# exact missing source marker instead of exiting silently under set -e.
source_checks = [
    ("src/freedreno/fdl/freedreno_layout.h", "bool has_explicit_pitch : 1;", "FDL explicit-pitch flag"),
    ("src/freedreno/fdl/freedreno_layout.h", "if (level == 0 && layout->has_explicit_pitch)", "FDL explicit level-0 pitch"),
    ("src/freedreno/vulkan/tu_image.cc", "pitch_alignment = android_yv12_import ? 16u : 0u", "YV12 16-byte pitch"),
    ("src/freedreno/vulkan/tu_image.cc", "android_yv12_import || android_exact_linear_color_import", "exact linear tail-padding policy"),
    ("src/freedreno/vulkan/tu_image.cc", "tu_is_android_yv12_import", "YV12 import recognizer"),
    ("src/freedreno/vulkan/tu_image.h", "android_external_no_gmem_padding", "exact linear AHB flag"),
    ("src/freedreno/vulkan/tu_image.cc", "tu_is_android_exact_linear_color_import", "exact linear AHB recognizer"),
    ("src/freedreno/vulkan/tu_image.cc", "Android image binding exceeds dma-buf size", "Android dma-buf bounds check"),
    ("src/freedreno/vulkan/tu_clear_blit.cc", "tu_attachment_gmem_edge_unaligned", "bounded GMEM edge helper"),
    ("src/freedreno/vulkan/tu_clear_blit.cc", "bounded_external_load", "bounded GMEM load path"),
    ("src/util/u_gralloc/u_gralloc_qcom.c", "TG_QTI_NV12_UBWC_FORMAT 0x7fa30c06", "QTI private NV12 UBWC format"),
    ("src/util/u_gralloc/u_gralloc_qcom.c", "TG_QTI_TP10_UBWC_FORMAT 0x7fa30c09", "QTI private TP10 UBWC format"),
    ("src/util/u_gralloc/u_gralloc_qcom.c", "TG_QTI_GET_YUV_PLANE_LAYOUTS_SYMBOL", "QTI PlaneLayoutInfo runtime ABI"),
    ("src/util/u_gralloc/u_gralloc_qcom.c", "DRM_FORMAT_NV15", "QTI TP10 NV15 mapping"),
    ("src/util/u_gralloc/u_gralloc_qcom.c", "touchGrass: imported QTI NV12 UBWC 0x7fa30c06 via legacy PlaneLayoutInfo", "QTI NV12 UBWC import path"),
    ("src/util/u_gralloc/u_gralloc_qcom.c", "touchGrass: imported QTI TP10 UBWC 0x7fa30c09 as NV15 via legacy PlaneLayoutInfo", "QTI TP10 UBWC import path"),
]
for rel, needle, label in source_checks:
    if needle not in (src / rel).read_text():
        raise SystemExit(f"source audit failed: {label}: {needle}")
    print(f"source_audit={label}:PASS")
PY

echo "==> Fix KGSL zero-timeout Vulkan fence polling"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
path = src / "src/freedreno/vulkan/tu_knl_kgsl.cc"
text = path.read_text()

old = """static VkResult
wait_timestamp_safe(int fd,
                    unsigned int context_id,
                    unsigned int timestamp,
                    uint64_t abs_timeout_ns)
{
   struct kgsl_device_waittimestamp_ctxtid wait = {
      .context_id = context_id,
      .timestamp = timestamp,
      .timeout = get_relative_ms(abs_timeout_ns),
   };

   while (true) {
      int ret = ioctl(fd, IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID, &wait);

      if (ret == -1 && (errno == EINTR || errno == EAGAIN)) {
         int timeout_ms = get_relative_ms(abs_timeout_ns);

         /* update timeout to consider time that has passed since the start */
         if (timeout_ms == 0)
            return VK_TIMEOUT;

         wait.timeout = timeout_ms;
"""

new = """static VkResult
wait_timestamp_safe(int fd,
                    unsigned int context_id,
                    unsigned int timestamp,
                    uint64_t abs_timeout_ns)
{
   int timeout_ms = get_relative_ms(abs_timeout_ns);

   /* Vulkan timeout=0 is a non-blocking poll.  On the legacy KGSL used by
    * a52xq, WAITTIMESTAMP_CTXTID with timeout=0 can sleep the caller until
    * retirement.  Poll the retired timestamp directly instead so
    * vkGetFenceStatus() remains non-blocking as required by Vulkan.
    */
   if (timeout_ms == 0) {
      struct kgsl_cmdstream_readtimestamp_ctxtid req = {
         .context_id = context_id,
         .type = KGSL_TIMESTAMP_RETIRED,
      };

      int ret =
         ioctl(fd, IOCTL_KGSL_CMDSTREAM_READTIMESTAMP_CTXTID, &req);
      if (ret == 0 && timestamp_cmp(req.timestamp, timestamp))
         return VK_SUCCESS;

      return VK_TIMEOUT;
   }

   struct kgsl_device_waittimestamp_ctxtid wait = {
      .context_id = context_id,
      .timestamp = timestamp,
      .timeout = timeout_ms,
   };

   while (true) {
      int ret = ioctl(fd, IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID, &wait);

      if (ret == -1 && (errno == EINTR || errno == EAGAIN)) {
         timeout_ms = get_relative_ms(abs_timeout_ns);

         /* update timeout to consider time that has passed since the start */
         if (timeout_ms == 0)
            return VK_TIMEOUT;

         wait.timeout = timeout_ms;
"""

if text.count(old) != 1:
    raise SystemExit(
        f"KGSL zero-timeout poll anchor count: {text.count(old)}"
    )

header = src / "src/freedreno/vulkan/msm_kgsl.h"
header_text = header.read_text()
for needle in (
    "struct kgsl_cmdstream_readtimestamp_ctxtid",
    "KGSL_TIMESTAMP_RETIRED",
    "IOCTL_KGSL_CMDSTREAM_READTIMESTAMP_CTXTID",
):
    if needle not in header_text:
        raise SystemExit(f"KGSL ABI prerequisite missing: {needle}")

text = text.replace(old, new, 1)
path.write_text(text)

for needle in (
    "Vulkan timeout=0 is a non-blocking poll",
    "IOCTL_KGSL_CMDSTREAM_READTIMESTAMP_CTXTID",
    "KGSL_TIMESTAMP_RETIRED",
):
    if needle not in path.read_text():
        raise SystemExit(f"KGSL zero-timeout source audit failed: {needle}")

print("source_audit=KGSL zero-timeout retired-timestamp poll:PASS")
PY

grep -Fq 'Vulkan timeout=0 is a non-blocking poll' \
  "$SRC/src/freedreno/vulkan/tu_knl_kgsl.cc"
grep -Fq 'IOCTL_KGSL_CMDSTREAM_READTIMESTAMP_CTXTID' \
  "$SRC/src/freedreno/vulkan/tu_knl_kgsl.cc"

echo "==> Fix KGSL mixed timestamp/sync-FD merge"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
path = src / "src/freedreno/vulkan/tu_knl_kgsl.cc"
text = path.read_text()

# Mesa 26.2.2 has two object-selection bugs in kgsl_syncobj_merge().
#
# 1) TS + TS from different queues:
#    it changes ret to FD state before converting ret's timestamp and then
#    tries to merge ret.fd even though ret was a timestamp sync object.
#
# 2) TS + FD:
#    it calls kgsl_syncobj_ts_to_fd(sync) on the incoming FD object instead
#    of converting ret, the timestamp object.  Release builds compile out the
#    state assert, so timestamp_to_fd() dereferences sync->queue.  Imported
#    sync-FD objects do not have a queue, producing the Warframe null-pointer
#    crash observed at vulkan.adreno.so+0xa5ce44.
#
# Convert the actual TS object(s) first, then change the merged result to FD.

old_cross_queue = """            } else {
               ret.state = KGSL_SYNCOBJ_STATE_FD;
               int sync_fd = kgsl_syncobj_ts_to_fd(sync);
               ret.fd = sync_merge_close("tu_sync", ret.fd, sync_fd, true);
               assert(ret.fd >= 0);
            }
"""
new_cross_queue = """            } else {
               int ret_fd = kgsl_syncobj_ts_to_fd(&ret);
               int sync_fd = kgsl_syncobj_ts_to_fd(sync);
               ret.state = KGSL_SYNCOBJ_STATE_FD;
               ret.fd =
                  sync_merge_close("tu_sync", ret_fd, sync_fd, true);
               assert(ret.fd >= 0);
            }
"""
if text.count(old_cross_queue) != 1:
    raise SystemExit(
        f"KGSL cross-queue TS merge anchor count: {text.count(old_cross_queue)}")
text = text.replace(old_cross_queue, new_cross_queue, 1)

old_ts_fd = """         } else if (ret.state == KGSL_SYNCOBJ_STATE_TS) {
            ret.state = KGSL_SYNCOBJ_STATE_FD;
            int sync_fd = kgsl_syncobj_ts_to_fd(sync);
            ret.fd = sync_merge_close("tu_sync", ret.fd, sync_fd, true);
            assert(ret.fd >= 0);
         } else {
"""
new_ts_fd = """         } else if (ret.state == KGSL_SYNCOBJ_STATE_TS) {
            int ret_fd = kgsl_syncobj_ts_to_fd(&ret);
            ret.state = KGSL_SYNCOBJ_STATE_FD;
            ret.fd =
               sync_merge_close("tu_sync", ret_fd, sync->fd, false);
            assert(ret.fd >= 0);
         } else {
"""
if text.count(old_ts_fd) != 1:
    raise SystemExit(
        f"KGSL TS+FD merge anchor count: {text.count(old_ts_fd)}")
text = text.replace(old_ts_fd, new_ts_fd, 1)

path.write_text(text)

patched = path.read_text()
for needle in (
    "int ret_fd = kgsl_syncobj_ts_to_fd(&ret);",
    'sync_merge_close("tu_sync", ret_fd, sync->fd, false)',
    'sync_merge_close("tu_sync", ret_fd, sync_fd, true)',
):
    if needle not in patched:
        raise SystemExit(f"KGSL sync merge source audit failed: {needle}")

# The known-bad release-build path must be gone.
if """ret.state = KGSL_SYNCOBJ_STATE_FD;
            int sync_fd = kgsl_syncobj_ts_to_fd(sync);
            ret.fd = sync_merge_close("tu_sync", ret.fd, sync_fd, true);""" in patched:
    raise SystemExit("known-bad KGSL TS+FD merge survived")

print("source_audit=KGSL mixed TS/sync-FD merge fix:PASS")
print("source_audit=KGSL cross-queue TS/TS merge fix:PASS")
PY

grep -Fq 'sync_merge_close("tu_sync", ret_fd, sync->fd, false)' \
  "$SRC/src/freedreno/vulkan/tu_knl_kgsl.cc"
grep -Fq 'sync_merge_close("tu_sync", ret_fd, sync_fd, true)' \
  "$SRC/src/freedreno/vulkan/tu_knl_kgsl.cc"

echo "==> Keep upstream Turnip Vulkan 1.4 API"
grep -Fq '#define TU_API_VERSION VK_MAKE_VERSION(1, 4, VK_HEADER_VERSION)' \
  "$SRC/src/freedreno/vulkan/tu_device.cc"
test "$(grep -F "'--api-version', '1.4'" "$SRC/src/freedreno/vulkan/meson.build" | wc -l)" -eq 2

echo "==> Promote only Adreno 619 (chip_id 0x06010900) to Vulkan 1.4"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
path = src / "src/freedreno/vulkan/tu_device.cc"
text = path.read_text()

old = """   props->apiVersion =
      tu_has_multiview(pdevice) ?
         ((pdevice->info->chip >= 7) ? TU_API_VERSION :
            VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION))
         : VK_MAKE_VERSION(1, 0, VK_HEADER_VERSION);
"""

new = """   props->apiVersion =
      tu_has_multiview(pdevice) ?
         ((pdevice->info->chip >= 7 ||
           pdevice->dev_id.chip_id == 0x06010900) ? TU_API_VERSION :
            VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION))
         : VK_MAKE_VERSION(1, 0, VK_HEADER_VERSION);
"""

if text.count(old) != 1:
    raise SystemExit(f"A619 Vulkan 1.4 physical-device API anchor count: {text.count(old)}")

path.write_text(text.replace(old, new, 1))
PY

grep -Fq 'pdevice->dev_id.chip_id == 0x06010900' "$SRC/src/freedreno/vulkan/tu_device.cc"
grep -Fq '((pdevice->info->chip >= 7 ||' "$SRC/src/freedreno/vulkan/tu_device.cc"

echo "==> Remove legacy-KGSL dead probes and bring-up logging"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])

# The A52 legacy KGSL does not implement GPUMEM_BIND_RANGES. Mesa's virtual-BO
# capability test issues that unsupported ioctl once per Vulkan device, which
# only produces an -EINVAL result plus kernel log noise. The end state is
# always has_sparse=false. Keep that exact end state without the doomed ioctl.
kgsl = src / "src/freedreno/vulkan/tu_knl_kgsl.cc"
text = kgsl.read_text()
name = "kgsl_is_virtual_bo_supported("
name_pos = text.find(name)
if name_pos < 0:
    raise SystemExit("legacy KGSL virtual-BO probe function not found")
start = text.rfind("static bool", 0, name_pos)
brace = text.find("{", name_pos)
if start < 0 or brace < 0:
    raise SystemExit("legacy KGSL virtual-BO probe bounds not found")

depth = 0
end = None
for i in range(brace, len(text)):
    c = text[i]
    if c == "{":
        depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0:
            end = i
            break
if end is None:
    raise SystemExit("legacy KGSL virtual-BO probe closing brace not found")

old_func = text[start:end + 1]
if "IOCTL_KGSL_GPUMEM_BIND_RANGES" not in old_func:
    raise SystemExit("legacy KGSL virtual-BO probe no longer uses GPUMEM_BIND_RANGES")

signature = text[start:brace]
new_func = signature + """{
   /* touchGrass A52 legacy KGSL: GPUMEM_BIND_RANGES is not implemented.
    * Mesa's runtime probe always fails and only creates an unnecessary ioctl
    * plus a kernel log entry. Preserve the resulting capability state without
    * issuing the unsupported ioctl.
    */
   return false;
}"""
text = text[:start] + new_func + text[end + 1:]
kgsl.write_text(text)

patched = kgsl.read_text()
probe_start = patched.find(name)
probe_fn_start = patched.rfind("static bool", 0, probe_start)
probe_brace = patched.find("{", probe_start)
probe_end = patched.find("}", probe_brace)
probe_body = patched[probe_fn_start:probe_end + 1]
if "IOCTL_KGSL_GPUMEM_BIND_RANGES" in probe_body:
    raise SystemExit("legacy KGSL GPUMEM_BIND_RANGES call survived")
if "return false;" not in probe_body:
    raise SystemExit("legacy KGSL virtual-BO probe does not return false")
print("source_audit=legacy KGSL virtual-BO probe skipped:PASS")

# Remove successful bring-up traces from normal Android buffer import paths.
# Keep warnings/errors that indicate an actual import failure.
p = src / "src/util/u_gralloc/u_gralloc_internal.c"
text = p.read_text()
mapped_log_branch = """      if (mapped_yv12)
         mesa_logi("touchGrass: normalized mapped QCOM YV12 android_ycbcr pointers");
      else if (mapped_explicit_nv21)
         mesa_logi("touchGrass: normalized mapped QCOM explicit NV21 android_ycbcr pointers");
      else
         mesa_logi("touchGrass: normalized mapped QCOM flexible YUV420 android_ycbcr pointers");
"""
if text.count(mapped_log_branch) != 1:
    raise SystemExit(
        f"mapped-YUV success-log branch count: {text.count(mapped_log_branch)}")
text = text.replace(mapped_log_branch, "", 1)

# Some Mesa/source-transform combinations also leave standalone YV12 success
# messages inside real normalization blocks. Remove any that remain, but do
# not require a fixed count: the preceding composed transforms may already
# have consumed them.
yv12_success = '      mesa_logi("touchGrass: normalized mapped QCOM YV12 android_ycbcr pointers");\n'
text = text.replace(yv12_success, "")
p.write_text(text)

p = src / "src/vulkan/runtime/vk_android.c"
text = p.read_text()
line = '      mesa_logi("touchGrass: resolved flexible Android YUV420 CrCb as NV21");\n'
if text.count(line) != 1:
    raise SystemExit("NV21 resolution success-log anchor mismatch")
text = text.replace(line, "", 1)

trace_start = text.find("   const bool tg_qti_private =")
if trace_start < 0:
    raise SystemExit("QTI stderr trace start not found")
trace_end_marker = "      fflush(stderr);\n   }\n\n"
trace_end = text.find(trace_end_marker, trace_start)
if trace_end < 0:
    raise SystemExit("QTI stderr trace end not found")
trace_end += len(trace_end_marker)
text = text[:trace_start] + text[trace_end:]
p.write_text(text)

p = src / "src/util/u_gralloc/u_gralloc_qcom.c"
text = p.read_text()

success_block = """   if (is_tp10_ubwc)
      mesa_logi("touchGrass: imported QTI TP10 UBWC 0x7fa30c09 as NV15 via legacy PlaneLayoutInfo");
   else
      mesa_logi("touchGrass: imported QTI NV12 UBWC 0x7fa30c06 via legacy PlaneLayoutInfo");
"""
if text.count(success_block) != 1:
    raise SystemExit("QTI import success-log block mismatch")
text = text.replace(success_block, "", 1)

helper_log = '      mesa_logi("touchGrass: QTI legacy PlaneLayoutInfo helper available");\n'
if text.count(helper_log) != 1:
    raise SystemExit("QTI helper success-log anchor mismatch")
text = text.replace(helper_log, "", 1)

# TP10's verbose bring-up diagnostics intentionally used ERROR severity even
# on successful imports. They are useful for development but inappropriate
# for a daily driver. Every remaining "if (is_tp10_ubwc)" in this helper only
# guards a diagnostic mesa_loge block; the actual TP10 decisions use booleans
# and ternaries outside these guards.
diag_count = text.count("if (is_tp10_ubwc)")
if diag_count < 8:
    raise SystemExit(f"unexpected TP10 diagnostic guard count: {diag_count}")
text = text.replace("if (is_tp10_ubwc)", "if (false && is_tp10_ubwc)")

# Restore only the guards that lead to an actual rejection. Those execute
# solely on failure, so they retain high diagnostic value without polluting
# successful camera/video workloads.
for marker in (
    "touchGrass TP10 reject=hal_format",
    "touchGrass TP10 reject=handle_validation",
    "touchGrass TP10 reject=dma_size",
    "touchGrass TP10 reject=plane_query",
    "touchGrass TP10 reject=plane_validation",
    "touchGrass TP10 reject=plane_order",
    "touchGrass TP10 reject=ycbcr_crosscheck",
):
    pos = text.find(marker)
    if pos < 0:
        raise SystemExit(f"TP10 rejection marker missing: {marker}")
    guard = text.rfind("if (false && is_tp10_ubwc)", 0, pos)
    if guard < 0 or pos - guard > 500:
        raise SystemExit(f"TP10 rejection guard not found near: {marker}")
    text = text[:guard] + text[guard:].replace(
        "if (false && is_tp10_ubwc)", "if (is_tp10_ubwc)", 1)

p.write_text(text)

p = src / "src/freedreno/vulkan/tu_image.cc"
text = p.read_text()
needle = """      mesa_logi("touchGrass: validated native TP10 UBWC layout pitch=%" PRIu64
                " uv_meta=%" PRIu64, pitch, expected_uv_meta);
"""
if text.count(needle) != 1:
    raise SystemExit("TP10 validation success-log anchor mismatch")
text = text.replace(needle, "", 1)
p.write_text(text)

# Final audit: successful paths should not contain touchGrass info traces or
# direct stderr flushes. Error/warning strings are intentionally retained.
for rel in (
    "src/util/u_gralloc/u_gralloc_internal.c",
    "src/util/u_gralloc/u_gralloc_qcom.c",
    "src/vulkan/runtime/vk_android.c",
    "src/freedreno/vulkan/tu_image.cc",
):
    data = (src / rel).read_text()
    if 'mesa_logi("touchGrass:' in data:
        raise SystemExit(f"success trace survived in {rel}")
    if "fflush(stderr)" in data:
        raise SystemExit(f"stderr flush survived in {rel}")
print("source_audit=runtime bring-up success logging removed:PASS")
PY

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CROSS="$WORK/android-aarch64.ini"
cat > "$CROSS" <<EOF
[constants]
ndk_path = '$NDK'
toolchain = ndk_path / 'toolchains/llvm/prebuilt/linux-x86_64'

[binaries]
ar = toolchain / 'bin/llvm-ar'
c = ['ccache', toolchain / 'bin/aarch64-linux-android${ANDROID_API}-clang']
cpp = ['ccache', toolchain / 'bin/aarch64-linux-android${ANDROID_API}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = toolchain / 'bin/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

echo "==> Configure Mesa Turnip A619/KGSL"
meson setup "$BUILD" "$SRC"   --cross-file "$CROSS"   --buildtype release   -Db_ndebug=true   -Dplatforms=android   -Dplatform-sdk-version="$ANDROID_API"   -Dandroid-stub=true   -Dandroid-libbacktrace=disabled   -Dandroid-libperfetto=disabled   -Dexpat=disabled   -Dxmlconfig=disabled   -Degl=disabled   -Dgles1=disabled   -Dgles2=disabled   -Dopengl=false   -Dgbm=disabled   -Dglx=disabled   -Dgallium-drivers=   -Dvulkan-drivers=freedreno   -Dvulkan-layers=   -Dfreedreno-kmds=kgsl   -Dllvm=disabled   -Dvalgrind=disabled   -Dlibunwind=disabled   -Dlmsensors=disabled   -Dperfetto=false   -Dzstd=disabled   -Dzlib=enabled   -Dbuild-tests=false   -Dtools=   -Dvideo-codecs=   -Dtu-build-id=15799e6d32f2965a70353013be22dc22a9d57c012b9085f860e94bd349821eac

echo "==> Compile Turnip"
meson compile -C "$BUILD"

DRIVER="$BUILD/src/freedreno/vulkan/libvulkan_freedreno.so"
test -s "$DRIVER"

echo "==> Stage Android Vulkan HAL"
cp "$DRIVER" "$DIST/vulkan.adreno.so"
patchelf --set-soname vulkan.adreno.so "$DIST/vulkan.adreno.so"
patchelf --remove-rpath "$DIST/vulkan.adreno.so"
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$DIST/vulkan.adreno.so"

echo "==> Audit HAL"
readelf -d "$DIST/vulkan.adreno.so" | tee "$OUT/readelf-dynamic.txt"
readelf -Ws "$DIST/vulkan.adreno.so" | tee "$OUT/readelf-symbols.txt" >/dev/null
readelf -d "$DIST/vulkan.adreno.so" | grep -Fq '(SONAME)'
readelf -d "$DIST/vulkan.adreno.so" | grep -Fq 'vulkan.adreno.so'
! readelf -d "$DIST/vulkan.adreno.so" | grep -Fq '(RUNPATH)'
readelf -Ws "$DIST/vulkan.adreno.so" | grep -Eq '[[:space:]]HMI$'
for lib in libhardware.so liblog.so libnativewindow.so libsync.so libc.so; do
  readelf -d "$DIST/vulkan.adreno.so" | grep -Fq "Shared library: [$lib]"
done
file "$DIST/vulkan.adreno.so" | tee "$OUT/file.txt"
file "$DIST/vulkan.adreno.so" | grep -Fq 'ARM aarch64'
sha256sum "$DIST/vulkan.adreno.so" | tee "$OUT/vulkan.adreno.so.sha256"

echo "==> Build Vulkan 1.4 push-descriptor compute shader"
V14_PUSH_SHADER_SRC="$ROOT/scripts/92_turnip_vulkan14_push.comp"
V14_PUSH_SPV="$OUT/vulkan14_push.spv"
V14_PUSH_HDR="$OUT/vulkan14_push_spv.h"
test -s "$V14_PUSH_SHADER_SRC"
glslangValidator -V --target-env vulkan1.1 -S comp \
  "$V14_PUSH_SHADER_SRC" -o "$V14_PUSH_SPV"
python3 - "$V14_PUSH_SPV" "$V14_PUSH_HDR" <<'PY'
from pathlib import Path
import struct
import sys

spv = Path(sys.argv[1]).read_bytes()
if len(spv) % 4:
    raise SystemExit("Vulkan 1.4 push SPIR-V size is not uint32 aligned")
words = struct.unpack("<%dI" % (len(spv) // 4), spv)
with open(sys.argv[2], "w") as out:
    out.write("#pragma once\n#include <stddef.h>\n#include <stdint.h>\n")
    out.write("static const uint32_t vulkan14_push_spv[] = {\n")
    for i in range(0, len(words), 8):
        chunk = words[i:i+8]
        out.write("    " + ", ".join(f"0x{w:08x}u" for w in chunk) + ",\n")
    out.write("};\n")
    out.write("static const size_t vulkan14_push_spv_size = sizeof(vulkan14_push_spv);\n")
PY

echo "==> Build on-device Vulkan probe"
PROBE_SRC="$ROOT/scripts/92_turnip_vk_probe.c"
PROBE="$DIST/turnip-vk-probe"
test -s "$PROBE_SRC"
"$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang" \
  -O2 -Wall -Wextra -Werror -I"$OUT" \
  "$PROBE_SRC" -o "$PROBE" -lvulkan
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$PROBE"
chmod 0755 "$PROBE"
file "$PROBE" | tee "$OUT/probe-file.txt"
file "$PROBE" | grep -Fq 'ARM aarch64'
readelf -d "$PROBE" | tee "$OUT/probe-readelf-dynamic.txt"
readelf -d "$PROBE" | grep -Fq 'Shared library: [libvulkan.so]'
sha256sum "$PROBE" | tee "$OUT/turnip-vk-probe.sha256"

echo "==> Build on-device Android hardware-buffer import probe"
AHB_PROBE_SRC="$ROOT/scripts/92_turnip_ahb_probe.c"
AHB_PROBE="$DIST/turnip-ahb-probe"
test -s "$AHB_PROBE_SRC"
"$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang" \
  -O2 -Wall -Wextra -Werror \
  "$AHB_PROBE_SRC" -o "$AHB_PROBE" -lvulkan -landroid
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$AHB_PROBE"
chmod 0755 "$AHB_PROBE"
file "$AHB_PROBE" | tee "$OUT/ahb-probe-file.txt"
file "$AHB_PROBE" | grep -Fq 'ARM aarch64'
readelf -d "$AHB_PROBE" | tee "$OUT/ahb-probe-readelf-dynamic.txt"
readelf -d "$AHB_PROBE" | grep -Fq 'Shared library: [libvulkan.so]'
readelf -d "$AHB_PROBE" | grep -Fq 'Shared library: [libandroid.so]'
sha256sum "$AHB_PROBE" | tee "$OUT/turnip-ahb-probe.sha256"

echo "==> Build on-device YV12 GPU sampling probe"
YV12_SHADER_SRC="$ROOT/scripts/92_turnip_yv12_sample.comp"
YV12_PROBE_SRC="$ROOT/scripts/92_turnip_yv12_sample_probe.c"
YV12_SPV="$OUT/yv12_sample.spv"
YV12_HDR="$OUT/yv12_sample_spv.h"
YV12_PROBE="$DIST/turnip-yv12-sample-probe"
test -s "$YV12_SHADER_SRC"
test -s "$YV12_PROBE_SRC"
glslangValidator -V --target-env vulkan1.1 -S comp \
  "$YV12_SHADER_SRC" -o "$YV12_SPV"
python3 - "$YV12_SPV" "$YV12_HDR" <<'PY'
from pathlib import Path
import struct
import sys

spv = Path(sys.argv[1]).read_bytes()
if len(spv) % 4:
    raise SystemExit("SPIR-V size is not uint32 aligned")
words = struct.unpack("<%dI" % (len(spv) // 4), spv)
with open(sys.argv[2], "w") as out:
    out.write("#pragma once\n#include <stddef.h>\n#include <stdint.h>\n")
    out.write("static const uint32_t yv12_sample_spv[] = {\n")
    for i in range(0, len(words), 8):
        chunk = words[i:i+8]
        out.write("    " + ", ".join(f"0x{w:08x}u" for w in chunk) + ",\n")
    out.write("};\n")
    out.write("static const size_t yv12_sample_spv_size = sizeof(yv12_sample_spv);\n")
PY
"$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang" \
  -O2 -Wall -Wextra -Werror -I"$OUT" \
  "$YV12_PROBE_SRC" -o "$YV12_PROBE" -lvulkan -landroid
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$YV12_PROBE"
chmod 0755 "$YV12_PROBE"
file "$YV12_PROBE" | tee "$OUT/yv12-sample-probe-file.txt"
file "$YV12_PROBE" | grep -Fq 'ARM aarch64'
readelf -d "$YV12_PROBE" | tee "$OUT/yv12-sample-probe-readelf-dynamic.txt"
readelf -d "$YV12_PROBE" | grep -Fq 'Shared library: [libvulkan.so]'
readelf -d "$YV12_PROBE" | grep -Fq 'Shared library: [libandroid.so]'
sha256sum "$YV12_PROBE" "$YV12_SPV" | tee "$OUT/turnip-yv12-sample-probe.sha256"

cat > "$OUT/BUILD-INFO.txt" <<EOF
project=touchGrass Turnip A619 KGSL bring-up
mesa_version=26.2.2
mesa_archive_sha256=$MESA_SHA256
mesa_release_commit=3281a69a8bfd9f997e91c15ed0e6290cae12dd32
gpu=Adreno 619
kmd=KGSL
android_api=36
ndk=$(basename "$NDK")
turnip_api_cap=Vulkan-1.4
turnip_upstream_api=Vulkan-1.4
a619_vulkan14_override=device-id-0x06010900-only
kgsl_zero_timeout_poll=retired-timestamp-nonblocking
kgsl_virtual_bo_probe=disabled-known-legacy-a52xq
runtime_logging=errors-warnings-only-no-bringup-success-traces
kgsl_sync_merge=fixed-mixed-ts-syncfd-and-cross-queue-ts
driver_filename=vulkan.adreno.so
soname=vulkan.adreno.so
architecture=aarch64
probe=turnip-vk-probe
probe_api_request=Vulkan-1.4
probe_mode=device-submit-memory-verify-offscreen-dynamic-render-readback-vulkan14-feature-enable-dispatch-hostcopy-pushdescriptor-maintenance6-syncfd-ab-workload-scaling
ahb_probe=turnip-ahb-probe
ahb_probe_mode=rgba-yuv420-yv12-qti-nv12-tp10-native-import-bind-lifetime-yuv420-deep-forensics-nv21-fix
yv12_sample_probe=turnip-yv12-sample-probe
yv12_sample_mode=940x1670-postfill-importfirst-stock-reference-qcom-mapped-fix-plus-tp10-smoke
nv21_sample_mode=256x256-cbcr-asymmetric-four-point-stock-reference-compare
tp10_sample_mode=1080x1920-gpu-only-qti-ubwc-ycbcr-4point-compute-smoke
android_yv12_fix=mesa-26.2.2-explicit-layout-plus-qcom-mapped-pointer-normalization
android_flexible_yuv420_nv21_fix=YCrCb-step2-DRM-NV21-plus-opaque-external-format-swap
android_explicit_nv21_camera_fix=HAL_YCrCb_420_SP-0x11-to-DRM-NV21
android_linear_ahb_ccu_fix=76a4087d9e26fd2470936fae698827b6a2872528
qti_nv12_ubwc_fix=legacy-PlaneLayoutInfo-0x7fa30c06
qti_tp10_ubwc_fix=native-FMT6-TP10-NV15-QCOM-COMPRESSED-48x4-24x4-ubwc
qti_nv12_ubwc_reference_commit=6255156b8e6b868992ad085e3c4ddedcfb3b65f9
android_yv12_reference_commit=aeaf924c56adf7eddb0a9033b33474b48367e33d
build_id=15799e6d32f2965a70353013be22dc22a9d57c012b9085f860e94bd349821eac
EOF

echo "==> Turnip build complete"
