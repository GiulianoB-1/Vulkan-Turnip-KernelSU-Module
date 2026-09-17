#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: 95_patch_turnip_autotune_directlog.py <mesa-source-root>")

src = Path(sys.argv[1])
p = src / "src/freedreno/vulkan/tu_autotune.cc"
text = p.read_text()


def one(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"v0.35 {label}: expected 1 anchor, found {count}")
    text = text.replace(old, new, 1)


one(
    '#include "tu_autotune.h"\n',
    '#include "tu_autotune.h"\n\n#include <android/log.h>\n',
    'android log include',
)

marker = '#define TU_AUTOTUNE_FLUSH_AT_FINISH 0\n'
one(
    marker,
    marker + "\nstatic std::atomic<uint32_t> tg_diag_call_count { 0 };\n"
             "static std::atomic<uint32_t> tg_diag_bw_count { 0 };\n",
    'diagnostic counters',
)

# Heartbeat inside the constructor body.  Anchor on the unique suballocator
# initialization rather than the constructor signature so formatting changes
# in Mesa cannot hide the diagnostic.
ctor_body = (
    '   tu_bo_suballocator_init(&suballoc, device, 128 * 1024, '
    'TU_BO_ALLOC_INTERNAL_RESOURCE, "autotune_suballoc");\n'
)
one(
    ctor_body,
    '   std::string tg_cfg = active_config.load().to_string();\n'
    '   __android_log_print(ANDROID_LOG_WARN, "TGAT", "TGAT_INIT %s", tg_cfg.c_str());\n'
    + ctor_body,
    'constructor heartbeat',
)

entry = (
    '   cmd_buf_ctx &cb_ctx = cmd_buffer->autotune_ctx;\n'
    '   config_t config = active_config.load();\n\n'
)
one(
    entry,
    entry
    + '   const uint32_t tg_seq = tg_diag_call_count.fetch_add(1, std::memory_order_relaxed);\n'
      '   const bool tg_emit = tg_seq < 256;\n'
      '   if (tg_emit) {\n'
      '      __android_log_print(ANDROID_LOG_WARN, "TGAT",\n'
      '                          "TGAT_CALL seq=%" PRIu32 " draws=%" PRIu32 " enabled=%u simultaneous=%u tune_small=%u",\n'
      '                          tg_seq, rp_state->drawcall_count, enabled ? 1U : 0U,\n'
      '                          (cmd_buffer->usage_flags & VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT) ? 1U : 0U,\n'
      '                          config.test(mod_flag::TUNE_SMALL) ? 1U : 0U);\n'
      '   }\n\n',
    'selector entry',
)

one(
    '   if (rp_state->sysmem_single_prim_mode)\n      return render_mode::GMEM;\n',
    '   if (rp_state->sysmem_single_prim_mode) {\n'
    '      if (tg_emit)\n'
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT", "TGAT_DECISION seq=%" PRIu32 " reason=sysmem_single_prim mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n',
    'single prim decision',
)

one(
    '   if (pass->has_fdm)\n      return render_mode::GMEM;\n',
    '   if (pass->has_fdm) {\n'
    '      if (tg_emit)\n'
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT", "TGAT_DECISION seq=%" PRIu32 " reason=fdm mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n',
    'fdm decision',
)

one(
    '   if (pass->has_msrtss)\n      return render_mode::GMEM;\n',
    '   if (pass->has_msrtss) {\n'
    '      if (tg_emit)\n'
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT", "TGAT_DECISION seq=%" PRIu32 " reason=msrtss mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n',
    'msrtss decision',
)

one(
    '   if (!enabled || simultaneous_use || ignore_small_rp)\n      return default_mode;\n',
    '   if (!enabled || simultaneous_use || ignore_small_rp) {\n'
    '      if (tg_emit) {\n'
    '         const char *tg_reason = !enabled ? "disabled" : (simultaneous_use ? "simultaneous" : "small_rp");\n'
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT",\n'
    '                             "TGAT_DECISION seq=%" PRIu32 " reason=%s draws=%" PRIu32 " mode=SYSMEM",\n'
    '                             tg_seq, tg_reason, rp_state->drawcall_count);\n'
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
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT",\n'
    '                             "TGAT_DECISION seq=%" PRIu32 " reason=forced_early draws=%" PRIu32 " mode=%s",\n'
    '                             tg_seq, rp_state->drawcall_count, render_mode_str(*early_return_mode));\n'
    '      return *early_return_mode;\n'
    '   }\n'
)
one(old, new, 'forced early decision')

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
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT", "TGAT_DECISION seq=%" PRIu32 " reason=preempt mode=GMEM", tg_seq);\n'
    '      return render_mode::GMEM;\n'
    '   }\n'
)
one(old, new, 'preempt decision')

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
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT",\n'
    '                             "TGAT_DECISION seq=%" PRIu32 " reason=forced_late draws=%" PRIu32 " mode=%s",\n'
    '                             tg_seq, rp_state->drawcall_count, render_mode_str(*early_return_mode));\n'
    '      return *early_return_mode;\n'
    '   }\n'
)
one(old, new, 'forced late decision')

# Hook the stable bandwidth-algorithm call site rather than internal
# implementation formatting.  This records the actual final mode returned by
# the bandwidth algorithm while preserving behavior exactly.
bw_call = (
    '   if (config.is_enabled(algorithm::BANDWIDTH))\n'
    '      return history.bandwidth.get_optimal_mode(history, cmd_state, pass, framebuffer, rp_state);\n'
)
one(
    bw_call,
    '   if (config.is_enabled(algorithm::BANDWIDTH)) {\n'
    '      render_mode tg_bw_mode = history.bandwidth.get_optimal_mode(history, cmd_state, pass, framebuffer, rp_state);\n'
    '      const uint32_t tg_bw_seq = tg_diag_bw_count.fetch_add(1, std::memory_order_relaxed);\n'
    '      if (tg_bw_seq < 256)\n'
    '         __android_log_print(ANDROID_LOG_WARN, "TGAT",\n'
    '                             "TGAT_BW seq=%" PRIu32 " hash=%016" PRIx64 " draws=%" PRIu32 " mode=%s",\n'
    '                             tg_bw_seq, history.hash, rp_state->drawcall_count, render_mode_str(tg_bw_mode));\n'
    '      return tg_bw_mode;\n'
    '   }\n',
    'bandwidth caller',
)

p.write_text(text)
patched = p.read_text()
for needle in (
    '#include <android/log.h>',
    'TGAT_INIT %s',
    'TGAT_CALL seq=',
    'TGAT_DECISION seq=',
    'TGAT_BW seq=',
    '__android_log_print(ANDROID_LOG_WARN, "TGAT"',
):
    if needle not in patched:
        raise SystemExit(f"v0.35 direct-log audit missing: {needle}")

print('source_audit=Turnip direct Android autotune heartbeat:PASS')
print('source_audit=Turnip direct Android renderpass decisions:PASS')
print('source_audit=Turnip direct Android bandwidth decisions:PASS')
