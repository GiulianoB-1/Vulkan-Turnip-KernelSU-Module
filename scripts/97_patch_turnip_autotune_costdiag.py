#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: 97_patch_turnip_autotune_costdiag.py <mesa-source-root>")

src = Path(sys.argv[1])
p = src / "src/freedreno/vulkan/tu_autotune.cc"
text = p.read_text()


def one(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"v0.37 {label}: expected 1 anchor, found {count}")
    text = text.replace(old, new, 1)


counter_anchor = (
    'static std::atomic<uint32_t> tg_diag_call_count { 0 };\n'
    'static std::atomic<uint32_t> tg_diag_bw_count { 0 };\n'
)
one(
    counter_anchor,
    counter_anchor + 'static std::atomic<uint32_t> tg_diag_cost_count { 0 };\n',
    'cost counter',
)

mode_anchor = (
    '         bool select_sysmem = sysmem_bandwidth <= gmem_bandwidth;\n'
    '         render_mode mode = select_sysmem ? render_mode::SYSMEM : render_mode::GMEM;\n'
)
one(
    mode_anchor,
    mode_anchor
    + '         const uint32_t tg_cost_seq = tg_diag_cost_count.fetch_add(1, std::memory_order_relaxed);\n'
      '         if (tg_cost_seq < 512) {\n'
      '            const VkExtent2D &tg_extent = cmd_state->render_areas[0].extent;\n'
      '            tg_diag_emit("TGAT_COST seq=%" PRIu32 " hash=%016" PRIx64\n'
      '                         " draws=%" PRIu32 " px=%" PRIu32 " area=%" PRIu32 "x%" PRIu32\n'
      '                         " mean_samples=%" PRIu64 " draw_bps_sum=%" PRIu64 " draw_total=%" PRIu64\n'
      '                         " sys_pp=%" PRIu32 " gmem_pp=%" PRIu32\n'
      '                         " sys=%" PRIu64 " gmem=%" PRIu64 " mode=%s",\n'
      '                         tg_cost_seq, history.hash, rp_state->drawcall_count, pass_pixel_count,\n'
      '                         tg_extent.width, tg_extent.height, mean_samples,\n'
      '                         (uint64_t) rp_state->drawcall_bandwidth_per_sample_sum,\n'
      '                         total_draw_call_bandwidth, pass->sysmem_bandwidth_per_pixel,\n'
      '                         pass->gmem_bandwidth_per_pixel, sysmem_bandwidth, gmem_bandwidth,\n'
      '                         render_mode_str(mode));\n'
      '         }\n',
    'bandwidth cost telemetry',
)

p.write_text(text)
patched = p.read_text()
for needle in (
    'tg_diag_cost_count',
    'TGAT_COST seq=',
    'draw_bps_sum=',
    'sys_pp=',
    'gmem_pp=',
):
    if needle not in patched:
        raise SystemExit(f"v0.37 cost diagnostic audit missing: {needle}")

print('source_audit=Turnip bandwidth cost-model telemetry:PASS')
