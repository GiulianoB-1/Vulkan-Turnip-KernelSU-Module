# Testing rules

1. Branch behavior experiments from the v0.32 golden baseline.
2. Make one behavioral change at a time.
3. Keep diagnostic-only instrumentation separate from rendering-policy changes.
4. Compare against stock Qualcomm Vulkan where relevant.
5. Do not tune the kernel GPUBW governor, OPP tables, or bus policy to hide a Turnip-side bandwidth problem.
6. Keep KGSL NAP enabled and `idle_timer=40` unless a dedicated experiment proves otherwise.
7. Preserve the v0.32 KGSL sync-merge and Android YUV fixes.
