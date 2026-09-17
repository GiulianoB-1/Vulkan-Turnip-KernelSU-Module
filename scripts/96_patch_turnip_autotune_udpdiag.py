#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: 96_patch_turnip_autotune_udpdiag.py <mesa-source-root>")

src = Path(sys.argv[1])
vk = src / "src/freedreno/vulkan"
autotune = vk / "tu_autotune.cc"
device = vk / "tu_device.cc"
header = vk / "tu_tgdiag.h"

header.write_text(r'''#ifndef TU_TGDIAG_H
#define TU_TGDIAG_H

#include <arpa/inet.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define TG_DIAG_PORT 39353

static inline void
tg_diag_emit(const char *fmt, ...)
{
   static int sock = -2;
   static struct sockaddr_in addr;

   if (sock == -2) {
      sock = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
      if (sock >= 0) {
         memset(&addr, 0, sizeof(addr));
         addr.sin_family = AF_INET;
         addr.sin_port = htons(TG_DIAG_PORT);
         addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      }
   }

   if (sock < 0)
      return;

   char buf[512];
   int off = snprintf(buf, sizeof(buf), "pid=%d ", getpid());
   if (off < 0)
      return;
   if ((size_t) off >= sizeof(buf))
      off = sizeof(buf) - 1;

   va_list ap;
   va_start(ap, fmt);
   int n = vsnprintf(buf + off, sizeof(buf) - (size_t) off, fmt, ap);
   va_end(ap);
   if (n < 0)
      return;

   size_t len = (size_t) off + (size_t) n;
   if (len >= sizeof(buf))
      len = sizeof(buf) - 1;

   (void) sendto(sock, buf, len, MSG_DONTWAIT | MSG_NOSIGNAL,
                 (const struct sockaddr *) &addr, sizeof(addr));
}

#endif
''')


def patch_one(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"v0.36 {label}: expected 1 anchor, found {count}")
    path.write_text(text.replace(old, new, 1))


patch_one(
    autotune,
    '#include "tu_autotune.h"\n',
    '#include "tu_autotune.h"\n#include "tu_tgdiag.h"\n',
    'autotune diagnostic include',
)

patch_one(
    autotune,
    '#define TU_AUTOTUNE_FLUSH_AT_FINISH 0\n',
    '#define TU_AUTOTUNE_FLUSH_AT_FINISH 0\n\n'
    'static std::atomic<uint32_t> tg_diag_call_count { 0 };\n'
    'static std::atomic<uint32_t> tg_diag_bw_count { 0 };\n',
    'diagnostic counters',
)

ctor_body = (
    '   tu_bo_suballocator_init(&suballoc, device, 128 * 1024, '
    'TU_BO_ALLOC_INTERNAL_RESOURCE, "autotune_suballoc");\n'
)
patch_one(
    autotune,
    ctor_body,
    '   std::string tg_cfg = active_config.load().to_string();\n'
    '   tg_diag_emit("TGAT_INIT %s", tg_cfg.c_str());\n'
    + ctor_body,
    'constructor heartbeat',
)

entry = (
    '   cmd_buf_ctx &cb_ctx = cmd_buffer->autotune_ctx;\n'
    '   config_t config = active_config.load();\n\n'
)
patch_one(
    autotune,
    entry,
    entry
    + '   const uint32_t tg_seq = tg_diag_call_count.fetch_add(1, std::memory_order_relaxed);\n'
      '   const bool tg_emit = tg_seq < 256;\n'
      '   if (tg_emit) {\n'
      '      tg_diag_emit("TGAT_CALL seq=%" PRIu32 " draws=%" PRIu32 " enabled=%u simultaneous=%u tune_small=%u",\n'
      '                   tg_seq, rp_state->drawcall_count, enabled ? 1U : 0U,\n'
      '                   (cmd_buffer->usage_flags & VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT) ? 1U : 0U,\n'
      '                   config.test(mod_flag::TUNE_SMALL) ? 1U : 0U);\n'
      '   }\n\n',
    'selector entry',
)

patch_one(
    autotune,
    '   if (rp_state->sysmem_single_prim_mode)\n      return render_mode::GMEM;\n',
    '   if (rp_state->sysmem_single_prim_mode) {\n'
    '      if (tg_emit)\n'
    '         tg_diag_emit("TGAT_DECISION seq=%" PRIu32 " reason=sysmem_single_prim mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n',
    'single prim decision',
)

patch_one(
    autotune,
    '   if (pass->has_fdm)\n      return render_mode::GMEM;\n',
    '   if (pass->has_fdm) {\n'
    '      if (tg_emit)\n'
    '         tg_diag_emit("TGAT_DECISION seq=%" PRIu32 " reason=fdm mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n',
    'fdm decision',
)

patch_one(
    autotune,
    '   if (pass->has_msrtss)\n      return render_mode::GMEM;\n',
    '   if (pass->has_msrtss) {\n'
    '      if (tg_emit)\n'
    '         tg_diag_emit("TGAT_DECISION seq=%" PRIu32 " reason=msrtss mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n',
    'msrtss decision',
)

patch_one(
    autotune,
    '   if (!enabled || simultaneous_use || ignore_small_rp)\n      return default_mode;\n',
    '   if (!enabled || simultaneous_use || ignore_small_rp) {\n'
    '      if (tg_emit) {\n'
    '         const char *tg_reason = !enabled ? "disabled" : (simultaneous_use ? "simultaneous" : "small_rp");\n'
    '         tg_diag_emit("TGAT_DECISION seq=%" PRIu32 " reason=%s draws=%" PRIu32 " mode=SYSMEM",\n'
    '                      tg_seq, tg_reason, rp_state->drawcall_count);\n'
    '      }\n'
    '      return default_mode;\n'
    '   }\n',
    'default early decision',
)

old = (
    '   if (can_early_return && early_return_mode) {\n'
    '      at_log_base_h("%" PRIu32 " draw calls, using %s (early)",\n'
    '                    key_opt ? key_opt->hash : rp_key(pass, framebuffer, cmd_buffer).hash, rp_state->drawcall_count,\n'
    '                    render_mode_str(*early_return_mode));\n'
    '      return *early_return_mode;\n'
    '   }\n'
)
new = (
    '   if (can_early_return && early_return_mode) {\n'
    '      at_log_base_h("%" PRIu32 " draw calls, using %s (early)",\n'
    '                    key_opt ? key_opt->hash : rp_key(pass, framebuffer, cmd_buffer).hash, rp_state->drawcall_count,\n'
    '                    render_mode_str(*early_return_mode));\n'
    '      if (tg_emit)\n'
    '         tg_diag_emit("TGAT_DECISION seq=%" PRIu32 " reason=forced_early draws=%" PRIu32 " mode=%s",\n'
    '                      tg_seq, rp_state->drawcall_count, render_mode_str(*early_return_mode));\n'
    '      return *early_return_mode;\n'
    '   }\n'
)
patch_one(autotune, old, new, 'forced early decision')

old = (
    '   if (config.test(mod_flag::PREEMPT_OPTIMIZE) && history.preempt_optimize.is_latency_sensitive()) {\n'
    '      /* Try to mitigate the risk of high preemption latency by always using GMEM, which should break up any larger\n'
    '       * draws into smaller ones with tiling.\n'
    '       */\n'
    '      at_log_base_h("high preemption latency risk, using GMEM", key.hash);\n'
    '      return render_mode::GMEM;\n'
    '   }\n'
)
new = (
    '   if (config.test(mod_flag::PREEMPT_OPTIMIZE) && history.preempt_optimize.is_latency_sensitive()) {\n'
    '      /* Try to mitigate the risk of high preemption latency by always using GMEM, which should break up any larger\n'
    '       * draws into smaller ones with tiling.\n'
    '       */\n'
    '      at_log_base_h("high preemption latency risk, using GMEM", key.hash);\n'
    '      if (tg_emit)\n'
    '         tg_diag_emit("TGAT_DECISION seq=%" PRIu32 " reason=preempt mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n'
)
patch_one(autotune, old, new, 'preempt decision')

old = (
    '   if (early_return_mode) {\n'
    '      at_log_base_h("%" PRIu32 " draw calls, using %s (late)", key.hash, rp_state->drawcall_count,\n'
    '                    render_mode_str(*early_return_mode));\n'
    '      return *early_return_mode;\n'
    '   }\n'
)
new = (
    '   if (early_return_mode) {\n'
    '      at_log_base_h("%" PRIu32 " draw calls, using %s (late)", key.hash, rp_state->drawcall_count,\n'
    '                    render_mode_str(*early_return_mode));\n'
    '      if (tg_emit)\n'
    '         tg_diag_emit("TGAT_DECISION seq=%" PRIu32 " reason=forced_late draws=%" PRIu32 " mode=%s",\n'
    '                      tg_seq, rp_state->drawcall_count, render_mode_str(*early_return_mode));\n'
    '      return *early_return_mode;\n'
    '   }\n'
)
patch_one(autotune, old, new, 'forced late decision')

bw_call = (
    '   if (config.is_enabled(algorithm::BANDWIDTH))\n'
    '      return history.bandwidth.get_optimal_mode(history, cmd_state, pass, framebuffer, rp_state);\n'
)
patch_one(
    autotune,
    bw_call,
    '   if (config.is_enabled(algorithm::BANDWIDTH)) {\n'
    '      render_mode tg_bw_mode = history.bandwidth.get_optimal_mode(history, cmd_state, pass, framebuffer, rp_state);\n'
    '      const uint32_t tg_bw_seq = tg_diag_bw_count.fetch_add(1, std::memory_order_relaxed);\n'
    '      if (tg_bw_seq < 256)\n'
    '         tg_diag_emit("TGAT_BW seq=%" PRIu32 " hash=%016" PRIx64 " draws=%" PRIu32 " mode=%s",\n'
    '                      tg_bw_seq, history.hash, rp_state->drawcall_count, render_mode_str(tg_bw_mode));\n'
    '      return tg_bw_mode;\n'
    '   }\n',
    'bandwidth caller',
)

# Device-level heartbeat is deliberately outside tu_autotune.  Any process
# that actually creates a Turnip VkDevice should emit this packet, allowing us
# to distinguish transport failure from an autotune-construction issue.
patch_one(
    device,
    '#include "tu_device.h"\n',
    '#include "tu_device.h"\n#include "tu_tgdiag.h"\n',
    'device diagnostic include',
)
patch_one(
    device,
    '   VK_FROM_HANDLE(tu_physical_device, physical_device, physicalDevice);\n   VkResult result;\n',
    '   VK_FROM_HANDLE(tu_physical_device, physical_device, physicalDevice);\n'
    '   tg_diag_emit("TGAT_DEVICE");\n'
    '   VkResult result;\n',
    'device heartbeat',
)

for path, needles in (
    (autotune, ('TGAT_INIT %s', 'TGAT_CALL seq=', 'TGAT_DECISION seq=', 'TGAT_BW seq=', 'tg_diag_emit(')),
    (device, ('TGAT_DEVICE', 'tg_diag_emit(')),
    (header, ('TG_DIAG_PORT 39353', 'sendto(', 'INADDR_LOOPBACK')),
):
    data = path.read_text()
    for needle in needles:
        if needle not in data:
            raise SystemExit(f"v0.36 UDP diagnostic audit missing {needle!r} in {path.name}")

print('source_audit=Turnip UDP device heartbeat:PASS')
print('source_audit=Turnip UDP autotune heartbeat:PASS')
print('source_audit=Turnip UDP renderpass decisions:PASS')
print('source_audit=Turnip UDP bandwidth decisions:PASS')
